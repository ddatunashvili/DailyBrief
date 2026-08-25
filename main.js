// DailyBrief Electron shell.
// Opens brief-app.html in an app window and kicks off the daily pipeline
// (core\daily-brief.ps1) hidden in the background. The page never changes on
// disk: it reads each day's brief over IPC from the user's data folder.
//
// Storage: an embedded SQLite file (dailybrief.db) in that same data folder,
// one kv table. The pipeline works through files — briefs\*.json (today's
// plan) and done\*.json (what Claude reads next morning) — so files are
// synced into the store on start and after each run, and every done-save is
// mirrored back to disk. If SQLite can't open, the app falls back to the
// files and keeps working.
//
// The pure parts live in src\: text repair and json reading (text.js), the kv
// store (kv.js), run-file pruning (prune.js), the zoom ladder (zoom.js).

const { app, BrowserWindow, ipcMain, dialog, shell } = require('electron');
const { spawn } = require('child_process');
const path = require('path');
const fs = require('fs');
const crypto = require('crypto');
const { DATE_RE, listDates, deepFixMojibake, readJson } = require('./src/text');
const { initKv, kvReady, kvClose, kvGet, kvSet, kvKeys } = require('./src/kv');
const { pruneRunFiles: pruneDir } = require('./src/prune');
const { ZOOM_STEPS, clampZoom, nextZoom } = require('./src/zoom');

// Two roots, and they must not be confused.
//
//   APP_ROOT  - what the installer put on disk: the page, the icon and the
//               core\*.ps1 scripts with their prompts. Shared by everyone on
//               the machine, read-only, never written to at runtime.
//   DATA      - this user's own folder: briefs, kanban, the SQLite file, run
//               logs. One per Windows account, so two people on one PC never
//               see each other's day. Overridable with DAILYBRIEF_DATA, which
//               is also how a checked-out repo keeps its data in core\.
//
// A packaged build keeps core\ outside the asar (extraResources), so the
// scripts stay real files PowerShell can run.
const APP_ROOT = app.isPackaged ? process.resourcesPath : __dirname;
const CORE_DIR = path.join(APP_ROOT, 'core');
const DATA = process.env.DAILYBRIEF_DATA
  || (app.isPackaged ? path.join(app.getPath('userData'), 'data') : CORE_DIR);

// The page ships inside the asar in a packaged build, so it is addressed from
// the app path, not from resources.
const PAGE = path.join(app.isPackaged ? app.getAppPath() : __dirname, 'brief-app.html');

// Scripts: install side.
const PIPELINE = path.join(CORE_DIR, 'daily-brief.ps1');
const CHECK_SCRIPT = path.join(CORE_DIR, 'kanban-check.ps1');
const MONITOR_SCRIPT = path.join(CORE_DIR, 'monitor.ps1');
// Project registry: what the user's folders actually ARE (stack, commits,
// dirty files, TODOs). Built by a script, read by every AI run and the UI.
const DISCOVER_SCRIPT = path.join(CORE_DIR, 'discover-projects.ps1');
// Ask + ideas: two AI modes that only ever read the registry (core\ask.ps1).
const ASK_SCRIPT = path.join(CORE_DIR, 'ask.ps1');
// The only run that edits a real project: own branch, VS Code, Bash.
const EXECUTE_SCRIPT = path.join(CORE_DIR, 'execute.ps1');

// Data: user side.
const BRIEFS_DIR = path.join(DATA, 'briefs');
const LEGACY_DIR = path.join(DATA, 'briefings');
const DONE_DIR = path.join(DATA, 'done');
const PLANS_FILE = path.join(DATA, 'plans.json');
const KANBAN_FILE = path.join(DATA, 'kanban.json');
const PROJECTS_FILE = path.join(DATA, 'projects.json');
const ASK_LOG_FILE = path.join(DATA, 'ask-log.json');
const IDEAS_FILE = path.join(DATA, 'ideas.json');
const IGNORE_FILE = path.join(DATA, 'ignore.json');
const EXECUTE_REQUEST_FILE = path.join(DATA, 'execute-request.json');
const QUESTIONS_FILE = path.join(DATA, 'questions.json');
const ANALYTICS_DIR = path.join(DATA, 'analytics');
const SNAP_DIR = path.join(DATA, 'snapshots');
const ICON = path.join(APP_ROOT, 'build', 'icon.png');

// Own embedded database: SQLite file next to the data (no external server).
const DB_FILE = path.join(DATA, 'dailybrief.db');

// Every PowerShell child reads DAILYBRIEF_DATA to find the same folder this
// process picked, so main.js is the single place that decides where data goes.
const PS_ENV = Object.assign({}, process.env, { DAILYBRIEF_DATA: DATA });
const PS_OPTS = { windowsHide: true, stdio: 'ignore', env: PS_ENV };

// First run on a new account: create the folders the scripts expect to exist.
// Cheap enough to do unconditionally, and it keeps every writer downstream
// free of "does the parent exist" checks.
function ensureDataDirs() {
  for (const d of [DATA, BRIEFS_DIR, DONE_DIR, ANALYTICS_DIR, SNAP_DIR, path.join(DATA, 'scans')]) {
    try { fs.mkdirSync(d, { recursive: true }); } catch (e) { /* surfaced later by the first read */ }
  }
}
// Upgrade path for the builds that kept data inside the project folder: if
// this account has such a folder and its new data dir is still empty, move
// the data across once. Nothing is deleted — the old folder stays behind as
// its own backup — and the check is by folder shape, not by user name, so it
// is a no-op on a machine that never ran an older build.
function migrateLegacyData() {
  // The destination has to exist first: copying into a folder that was not
  // created yet throws ENOENT, and the catch below would swallow it, leaving
  // a brand-new data dir that looks migrated but holds nothing.
  try { fs.mkdirSync(DATA, { recursive: true }); } catch (e) { return; }
  if (fs.existsSync(path.join(DATA, 'kanban.json'))) return;
  const home = app.getPath('home');
  const legacy = [
    path.join(home, 'OneDrive', 'Desktop', 'DailyBriefApp', 'core'),
    path.join(home, 'Desktop', 'DailyBriefApp', 'core')
  ].find((d) => d !== DATA && fs.existsSync(path.join(d, 'kanban.json')));
  if (!legacy) return;
  // Only the data. The scripts and prompts sitting next to it belong to the
  // install now, and copying them would leave two divergent copies.
  // The -wal/-shm siblings come along: a database copied without its
  // write-ahead log loses whatever had not been checkpointed yet.
  const keep = /^(kanban|plans|projects|ideas|ignore|questions|ask-log|publish)\.json$|^(GOALS|STATE|PROGRESS)\.md$|^dailybrief\.db(-wal|-shm)?$|^(dirs|top-dirs)\.txt$|^ai-(runs|problems)\.jsonl$/;
  const dirs = ['briefs', 'briefings', 'done', 'analytics', 'snapshots', 'scans'];
  try {
    for (const f of fs.readdirSync(legacy)) {
      const src = path.join(legacy, f);
      const dst = path.join(DATA, f);
      if (fs.existsSync(dst)) continue;
      if (keep.test(f)) fs.copyFileSync(src, dst);
      else if (dirs.includes(f) && fs.statSync(src).isDirectory()) fs.cpSync(src, dst, { recursive: true });
    }
  } catch (e) { /* a partial copy still beats starting empty */ }
}
// Files the PowerShell scripts read unconditionally. Without them a fresh
// account's first run died inside Get-Content before it could write a log,
// which surfaced in the app as "claude CLI never wrote a log" — the one thing
// that was not wrong. Seeds are written only when the file is absent, so they
// never overwrite migrated or working data.
const SEED_FILES = [
  ['kanban.json', JSON.stringify({ tasks: [], archive: [] }, null, 2)],
  ['dirs.txt', ''],
  ['GOALS.md', ''],
  ['STATE.md', ''],
  ['PROGRESS.md', '']
];

function seedDataFiles() {
  for (const [name, contents] of SEED_FILES) {
    const p = path.join(DATA, name);
    if (fs.existsSync(p)) continue;
    try { fs.writeFileSync(p, contents, 'utf8'); } catch (e) { /* first read reports it */ }
  }
}

if (app.isPackaged) migrateLegacyData();
ensureDataDirs();
seedDataFiles();

// Run files pile up in the data folder; the module decides which families
// exist and how many of each to keep.
function pruneRunFiles() { pruneDir(DATA); }

/* ---------- SQLite (this user's dailybrief.db) ---------- */

function initDb() {
  // A store that failed to open is not fatal: every reader below falls back
  // to the JSON files the PowerShell side writes.
  if (initKv(DB_FILE)) syncFilesToDb();
}

function syncFilesToDb() {
  if (!kvReady()) return;
  // briefs + kanban: written by the pipeline — files are the source of truth.
  listDates(BRIEFS_DIR, '.json').forEach((date) => {
    const brief = readJson(path.join(BRIEFS_DIR, date + '.json'));
    if (brief) kvSet('brief:' + date, brief);
  });
  const kanban = readKanbanFile();
  if (kanban) kvSet('kanban', kanban);
  // done/plans: the app writes the DB first — seed only missing keys.
  listDates(DONE_DIR, '.json').forEach((date) => {
    if (!kvGet('done:' + date)) {
      const state = readJson(path.join(DONE_DIR, date + '.json'));
      if (state) kvSet('done:' + date, state);
    }
  });
  if (!kvGet('plans')) {
    const items = readJson(PLANS_FILE);
    if (Array.isArray(items) && items.length) kvSet('plans', items);
  }
}

function readKanbanFile() {
  const k = readJson(KANBAN_FILE);
  if (!k || !Array.isArray(k.tasks)) return null;
  return { tasks: k.tasks, archive: Array.isArray(k.archive) ? k.archive : [] };
}

/* ---------- IPC ---------- */

ipcMain.handle('brief:listDays', () => {
  const days = new Map();
  kvKeys('brief:').forEach((d) => { if (DATE_RE.test(d)) days.set(d, 'json'); });
  listDates(BRIEFS_DIR, '.json').forEach((d) => days.set(d, 'json'));
  listDates(LEGACY_DIR, '.md').forEach((d) => {
    if (!days.has(d)) days.set(d, 'md');
  });
  return Array.from(days, ([date, kind]) => ({ date, kind }))
    .sort((a, b) => b.date.localeCompare(a.date));
});

ipcMain.handle('brief:loadDay', (ev, date) => {
  if (!DATE_RE.test(String(date))) return null;
  const cached = kvGet('brief:' + date);
  if (cached) return { kind: 'json', brief: cached };
  const brief = readJson(path.join(BRIEFS_DIR, date + '.json'));
  if (brief) return { kind: 'json', brief };
  const mdPath = path.join(LEGACY_DIR, date + '.md');
  if (fs.existsSync(mdPath)) {
    return { kind: 'md', text: fs.readFileSync(mdPath, 'utf8') };
  }
  return null;
});

ipcMain.handle('brief:loadDone', (ev, date) => {
  if (!DATE_RE.test(String(date))) return {};
  const cached = kvGet('done:' + date);
  if (cached) return cached;
  return readJson(path.join(DONE_DIR, date + '.json')) || {};
});

// done entries: { done: bool, title?: string } — title is the user's own
// wording of the task, fed back to the next pipeline run as a signal.
ipcMain.handle('brief:saveDone', async (ev, date, state) => {
  if (!DATE_RE.test(String(date))) return false;
  const clean = {};
  Object.keys(state || {}).forEach((k) => {
    const v = state[k];
    const entry = { done: typeof v === 'object' && v !== null ? !!v.done : !!v };
    if (v && typeof v === 'object' && typeof v.title === 'string' && v.title.trim()) {
      entry.title = v.title.trim().slice(0, 300);
    }
    clean[String(k)] = entry;
  });
  kvSet('done:' + date, clean);
  // Always mirror to disk: the pipeline's Claude reads files, not the DB.
  fs.mkdirSync(DONE_DIR, { recursive: true });
  fs.writeFileSync(path.join(DONE_DIR, date + '.json'), JSON.stringify(clean, null, 2), 'utf8');
  return true;
});

ipcMain.handle('brief:replan', () => {
  if (pipelineRunning || activeRuns.size > 0) return false;
  runPipeline(true);
  return true;
});

/* Plans: the user's own worklist with statuses (urgent / important /
   delayed / planning). Mirrored to core\plans.json so the pipeline's
   Claude run reads it as a priority signal. */

const PLAN_STATUSES = ['urgent', 'important', 'delayed', 'planning'];

ipcMain.handle('plans:load', () => {
  const cached = kvGet('plans');
  if (Array.isArray(cached)) return cached;
  return readJson(PLANS_FILE) || [];
});

ipcMain.handle('plans:save', async (ev, items) => {
  const now = new Date().toISOString();
  const clean = (Array.isArray(items) ? items : []).slice(0, 500).map((p) => ({
    id: String(p && p.id || '').slice(0, 40),
    text: String(p && p.text || '').slice(0, 1000),
    status: PLAN_STATUSES.includes(p && p.status) ? p.status : 'planning',
    createdAt: (p && p.createdAt) || now,
    updatedAt: (p && p.updatedAt) || now
  })).filter((p) => p.id && p.text);
  kvSet('plans', clean);
  fs.writeFileSync(PLANS_FILE, JSON.stringify(clean, null, 2), 'utf8');
  return true;
});

/* Kanban: board data lives in Mongo + core\kanban.json. The file mirror is
   what the pipeline's Claude runs read and write, so saves always hit both. */

const KANBAN_STATUSES = ['urgent', 'important', 'planning', 'delayed', 'active'];

function sanitizeKanban(data) {
  const now = new Date().toISOString();
  const cleanList = (list, isArchive) => (Array.isArray(list) ? list : []).slice(0, 500).map((t) => {
    const out = {
      id: String(t && t.id || '').slice(0, 60),
      title: String(t && t.title || '').slice(0, 300),
      desc: String(t && t.desc || '').slice(0, 2000),
      status: KANBAN_STATUSES.includes(t && t.status) ? t.status : 'planning',
      done: !!(t && t.done),
      createdBy: (t && t.createdBy) === 'user' ? 'user' : 'ai',
      createdAt: (t && t.createdAt) || now,
      updatedAt: (t && t.updatedAt) || now,
      // state: "new" = a user comment the AI has not acted on yet. Saving the
      // board is what fires the command run, and the check script flips it to
      // "applied" when it's done.
      comments: (Array.isArray(t && t.comments) ? t.comments : []).slice(0, 100).map((c) => ({
        by: (c && c.by) === 'ai' ? 'ai' : 'user',
        text: String(c && c.text || '').slice(0, 1000),
        at: (c && c.at) || now,
        state: (c && c.state) === 'new' ? 'new' : 'applied'
      })),
      aiNotes: (Array.isArray(t && t.aiNotes) ? t.aiNotes : []).slice(-10).map((n) => ({
        text: String(n && n.text || '').slice(0, 500),
        at: (n && n.at) || now
      })),
      // User-linked folders: the check prompt watches these paths first.
      dirs: (Array.isArray(t && t.dirs) ? t.dirs : []).slice(0, 10)
        .map((d) => String(d || '').slice(0, 500)).filter(Boolean),
      // Checklist inside the task, separate from the free-text desc.
      subtasks: (Array.isArray(t && t.subtasks) ? t.subtasks : []).slice(0, 30).map((s) => ({
        text: String(s && s.text || '').slice(0, 300),
        done: !!(s && s.done)
      })).filter((s) => s.text),
      // Set once the first time the task is opened with an empty checklist, so
      // the auto-plan run fires exactly once per task.
      planRequested: !!(t && t.planRequested)
    };
    if (isArchive) out.archivedAt = (t && t.archivedAt) || now;
    return out;
  }).filter((t) => t.id && t.title);
  return { tasks: cleanList(data && data.tasks, false), archive: cleanList(data && data.archive, true) };
}

ipcMain.handle('kanban:load', () => {
  const cached = kvGet('kanban');
  if (cached && Array.isArray(cached.tasks)) return cached;
  return readKanbanFile() || { tasks: [], archive: [] };
});

ipcMain.handle('kanban:save', (ev, data) => {
  const clean = sanitizeKanban(data);
  kvSet('kanban', clean);
  fs.writeFileSync(KANBAN_FILE, JSON.stringify(clean, null, 2), 'utf8');
  // A user comment is an order inside that task's scope, not a sticky note:
  // every task carrying an unhandled comment gets its own tiny AI run.
  // The comment stays "new" until the run acks it in kanban.json, so any save
  // in the meantime would spawn a second run for the same comment.
  const commanding = new Set(Array.from(activeRuns.values())
    .filter((r) => r.mode === 'task-command')
    .map((r) => r.taskId));
  clean.tasks
    .filter((t) => !commanding.has(t.id))
    .filter((t) => (t.comments || []).some((c) => c.by === 'user' && c.state === 'new'))
    .slice(0, MAX_CONCURRENT_AI)
    .forEach((t) => runCheck(t.id, false, false, true));
  return true;
});

// Opening a task with an empty checklist plans it once, automatically —
// the user should never have to press "replan" to get a first plan.
ipcMain.handle('kanban:ensurePlan', (ev, taskId) => {
  const id = String(taskId || '').slice(0, 60);
  if (!id) return false;
  const board = kvGet('kanban') || readKanbanFile();
  if (!board) return false;
  const t = (board.tasks || []).find((x) => x.id === id);
  if (!t || t.done || t.planRequested) return false;
  if ((t.subtasks || []).length > 0) return false;
  // Mark first: the run is async and the board reloads when it lands, so the
  // flag is what stops a second open from firing another run.
  t.planRequested = true;
  kvSet('kanban', board);
  try { fs.writeFileSync(KANBAN_FILE, JSON.stringify(board, null, 2), 'utf8'); } catch (e) {}
  return runCheck(id, true, false, false);
});

ipcMain.handle('kanban:check', () => runCheck('', false, false));

ipcMain.handle('kanban:taskCheck', (ev, taskId) => (taskId ? runCheck(String(taskId).slice(0, 60), false, false) : false));

// One project's cards in one board column: the same check, scoped to the ids
// the board actually shows there instead of every active task.
ipcMain.handle('kanban:checkTasks', (ev, ids) => {
  const list = (Array.isArray(ids) ? ids : [])
    .map((x) => String(x || '').slice(0, 60)).filter(Boolean).slice(0, 40);
  return list.length ? runCheck('', false, false, false, list) : false;
});

ipcMain.handle('kanban:taskReplan', (ev, taskId) => (taskId ? runCheck(String(taskId).slice(0, 60), true, false) : false));

// Trajectory-based task generation: reads GOALS/STATE/PROGRESS instead of
// recent file activity, only ever proposes new tasks. Same concurrency pool
// as checks/replans (cheap, patch-only writes to kanban.json).
ipcMain.handle('kanban:generate', () => runCheck('', false, true));

/* Projects: the registry the AI plans from. Built by discover-projects.ps1
   (no AI), refreshed alongside the activity monitor. */

let discoverRunning = false;

function runDiscover() {
  if (discoverRunning) return false;
  discoverRunning = true;
  const ps = spawn('powershell.exe', [
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
    '-File', DISCOVER_SCRIPT
  ], PS_OPTS);
  ps.on('error', () => { discoverRunning = false; });
  ps.on('exit', () => {
    discoverRunning = false;
    if (win && !win.isDestroyed()) { try { win.webContents.send('projects:updated'); } catch (e) {} }
  });
  return true;
}

/* Ignored folders: everything under one of these paths is invisible to the
   whole app — the monitor stops logging it, the registry stops listing it,
   and no digest can mention it. The scripts read core\ignore.json themselves;
   this side also filters on read so muting takes effect immediately, without
   waiting for the next 30-minute scan. */

function readIgnore() {
  const data = readJson(IGNORE_FILE);
  const dirs = data && Array.isArray(data.dirs) ? data.dirs : [];
  return dirs.map((d) => String(d || '').trim()).filter(Boolean);
}

function isIgnored(p, list) {
  const t = String(p || '').trim().toLowerCase();
  if (!t) return false;
  return (list || readIgnore()).some((d) => {
    const s = String(d).toLowerCase().replace(/\\+$/, '');
    return t === s || t.startsWith(s + '\\');
  });
}

function writeIgnore(dirs) {
  const clean = [];
  dirs.map((d) => String(d || '').trim().replace(/\\+$/, '')).forEach((d) => {
    if (d && !clean.some((x) => x.toLowerCase() === d.toLowerCase())) clean.push(d);
  });
  const out = { dirs: clean.slice(0, 300), updatedAt: new Date().toISOString() };
  try { fs.writeFileSync(IGNORE_FILE, JSON.stringify(out, null, 2), 'utf8'); } catch (e) {}
  return out;
}

ipcMain.handle('projects:load', () => {
  const data = readJson(PROJECTS_FILE);
  if (!data || !Array.isArray(data.projects)) return { generatedAt: null, projects: [] };
  const ig = readIgnore();
  if (!ig.length) return data;
  return { generatedAt: data.generatedAt, projects: data.projects.filter((p) => !isIgnored(p && p.dir, ig)) };
});

ipcMain.handle('projects:refresh', () => runDiscover());

// Open a project folder in Explorer straight from the projects page.
ipcMain.handle('projects:open', (ev, dir) => {
  const p = String(dir || '');
  if (!p || !fs.existsSync(p)) return false;
  shell.openPath(p);
  return true;
});

/* Folder search for the ignore page: the same work roots the scripts walk,
   two levels deep, plus whatever the registry already found (a repo can sit
   deeper than two levels). Cached for a minute — the page searches on every
   keystroke. */

const SEARCH_ROOTS = [
  ['OneDrive', 'Desktop'], ['OneDrive', 'Documents'], ['Desktop'], ['Documents'],
  ['Downloads'], ['source'], ['projects']
].map((parts) => path.join(process.env.USERPROFILE || '', ...parts));

const SEARCH_SKIP = /node_modules|\\\.git($|\\)|AppData|\\Temp|\\\.vscode|__pycache__|\\\.venv|\\venv($|\\)|\\\.next|\\\.nuxt|\\\.output|\\\.turbo|\\\.cache|\\dist($|\\)|\\coverage($|\\)/i;

let dirCache = { at: 0, dirs: [] };

function listDirs(parent) {
  try {
    return fs.readdirSync(parent, { withFileTypes: true })
      .filter((d) => d.isDirectory())
      .map((d) => path.join(parent, d.name));
  } catch (e) {
    return [];
  }
}

function scanDirs() {
  if (dirCache.dirs.length && Date.now() - dirCache.at < 60 * 1000) return dirCache.dirs;
  const out = [];
  const add = (p) => {
    if (out.length >= 5000 || SEARCH_SKIP.test(p)) return;
    if (!out.some((x) => x.toLowerCase() === p.toLowerCase())) out.push(p);
  };
  SEARCH_ROOTS.filter((r) => fs.existsSync(r)).forEach((root) => {
    listDirs(root).forEach((d1) => {
      add(d1);
      listDirs(d1).forEach(add);
    });
  });
  const reg = readJson(PROJECTS_FILE);
  if (reg && Array.isArray(reg.projects)) reg.projects.forEach((p) => p && p.dir && add(String(p.dir)));
  dirCache = { at: Date.now(), dirs: out };
  return out;
}

ipcMain.handle('ignore:load', () => ({ dirs: readIgnore() }));

ipcMain.handle('ignore:add', (ev, dir) => {
  const p = String(dir || '').trim().replace(/\\+$/, '');
  if (!p || p.length < 3) return { dirs: readIgnore() };
  const next = writeIgnore(readIgnore().concat([p]));
  // Registry and analytics filter on read, so the change is visible at once.
  if (win && !win.isDestroyed()) { try { win.webContents.send('projects:updated'); } catch (e) {} }
  return next;
});

ipcMain.handle('ignore:remove', (ev, dir) => {
  const p = String(dir || '').trim().toLowerCase();
  const next = writeIgnore(readIgnore().filter((d) => d.toLowerCase() !== p));
  if (win && !win.isDestroyed()) { try { win.webContents.send('projects:updated'); } catch (e) {} }
  return next;
});

ipcMain.handle('ignore:search', (ev, query) => {
  const q = String(query || '').trim().toLowerCase();
  const ig = readIgnore();
  let dirs = scanDirs();
  if (q) dirs = dirs.filter((d) => d.toLowerCase().includes(q));
  return dirs.slice(0, 80).map((d) => ({ dir: d, ignored: isIgnored(d, ig) }));
});

/* Questions: the AI's open questions to the user. Without a place to answer
   them the model just repeated "waiting for David" in every briefing. */

function readQuestions() {
  const data = readJson(QUESTIONS_FILE);
  const list = data && Array.isArray(data.questions) ? data.questions : [];
  return list.slice(0, 50).map((q) => ({
    id: String(q && q.id || '').slice(0, 60),
    text: String(q && q.text || '').slice(0, 600),
    project: String(q && q.project || '').slice(0, 500),
    at: String(q && q.at || ''),
    answer: String(q && q.answer || '').slice(0, 1000),
    answeredAt: String(q && q.answeredAt || '')
  })).filter((q) => q.id && q.text);
}

ipcMain.handle('questions:load', () => readQuestions());

ipcMain.handle('questions:answer', (ev, id, answer) => {
  const qs = readQuestions();
  const q = qs.find((x) => x.id === String(id || ''));
  if (!q) return false;
  q.answer = String(answer || '').slice(0, 1000);
  q.answeredAt = new Date().toISOString().slice(0, 16).replace('T', ' ');
  fs.writeFileSync(QUESTIONS_FILE, JSON.stringify({ questions: qs }, null, 2), 'utf8');
  return true;
});

/* Settings: small key/value bag kept in the app database. */

const DEFAULT_SETTINGS = { autoUpdate: true, autoGenerate: true, autoPlanOnOpen: true, autoIdeas: true };

ipcMain.handle('settings:get', () => Object.assign({}, DEFAULT_SETTINGS, kvGet('settings') || {}));

ipcMain.handle('settings:set', (ev, patch) => {
  const cur = Object.assign({}, DEFAULT_SETTINGS, kvGet('settings') || {});
  Object.keys(patch || {}).forEach((k) => {
    if (k in DEFAULT_SETTINGS) cur[k] = !!patch[k];
  });
  kvSet('settings', cur);
  return cur;
});

/* Window zoom: the same ladder a browser walks with Ctrl +/-/0, kept in the
   database so the window opens at the size the user left it. */

function readZoom() {
  return clampZoom(kvGet('zoomFactor'));
}

function applyZoom(factor, notify) {
  const f = clampZoom(factor);
  kvSet('zoomFactor', f);
  if (win && !win.isDestroyed()) {
    win.webContents.setZoomFactor(f);
    if (notify !== false) win.webContents.send('zoom:changed', f);
  }
  return f;
}

// Next rung up or down the ladder from wherever the current factor sits.
function stepZoom(dir) { return applyZoom(nextZoom(readZoom(), dir)); }

// Ctrl +/-/0 and Ctrl+wheel, wired on the window's web contents because the
// menu bar (and with it the default accelerators) is hidden.
function wireZoom(w) {
  const wc = w.webContents;
  wc.on('did-finish-load', () => { wc.setZoomFactor(readZoom()); });
  wc.on('before-input-event', (ev, input) => {
    if (input.type !== 'keyDown' || !(input.control || input.meta) || input.alt) return;
    const k = String(input.key || '');
    if (k === '+' || k === '=' || k === 'Add') { ev.preventDefault(); stepZoom(1); }
    else if (k === '-' || k === '_' || k === 'Subtract') { ev.preventDefault(); stepZoom(-1); }
    else if (k === '0') { ev.preventDefault(); stepZoom(0); }
  });
  wc.on('zoom-changed', (ev, direction) => { stepZoom(direction === 'in' ? 1 : -1); });
}

ipcMain.handle('zoom:get', () => ({ factor: readZoom(), steps: ZOOM_STEPS }));
ipcMain.handle('zoom:set', (ev, factor) => applyZoom(factor));
ipcMain.handle('zoom:step', (ev, dir) => stepZoom(Number(dir) || 0));

ipcMain.handle('app:info', () => ({
  version: app.getVersion(),
  packaged: app.isPackaged,
  appRoot: APP_ROOT,
  dataDir: DATA
}));

// Folder-drop task creation: resolve a dropped path to its directory + name.
ipcMain.handle('path:dirInfo', (ev, p) => {
  try {
    const full = String(p || '');
    const st = fs.statSync(full);
    const dir = st.isDirectory() ? full : path.dirname(full);
    return { dir, name: path.basename(dir) };
  } catch (e) {
    return null;
  }
});

ipcMain.handle('dialog:pickFolder', async () => {
  const r = await dialog.showOpenDialog(win, {
    properties: ['openDirectory'],
    title: 'აირჩიე ფოლდერი ტასკზე მისაბმელად'
  });
  return (r.canceled || !r.filePaths.length) ? null : r.filePaths[0];
});

/* Concurrent AI runs: several checks/replans/generates can be in flight at
   once (capped below), each tracked by its own short id so the AI page can
   show and cancel them individually. The daily pipeline (full/replan) stays
   exclusive — it rewrites kanban.json wholesale via Claude's own Write tool,
   so it must never overlap with anything else that touches the board. */
const MAX_CONCURRENT_AI = 4;
const activeRuns = new Map(); // id -> { id, mode, taskId, pid, startedAt, logFile, killed, exclusive, est }
let pipelineRunning = false;
let reloadTimer = null;

// Several runs can finish within moments of each other; coalesce into one
// reload instead of reloading (and losing scroll/typing) once per run.
function scheduleReload() {
  if (reloadTimer) clearTimeout(reloadTimer);
  reloadTimer = setTimeout(() => {
    reloadTimer = null;
    if (win && !win.isDestroyed()) win.reload();
  }, 1500);
}

function broadcastAiStatus() {
  const list = Array.from(activeRuns.values()).map((r) => ({
    id: r.id, mode: r.mode, taskId: r.taskId || null, startedAt: r.startedAt, est: r.est
  }));
  if (win && !win.isDestroyed()) {
    try { win.webContents.send('ai:status', list); } catch (e) { /* window closing */ }
  }
}

function readRuns() {
  try {
    return fs.readFileSync(AI_RUNS_FILE, 'utf8').split(/\r?\n/)
      .filter(Boolean)
      .map((l) => { try { return JSON.parse(l); } catch (e) { return null; } })
      .filter(Boolean);
  } catch (e) {
    return [];
  }
}

// full/replan run on sonnet (quality), checks on haiku (speed/price).
const EST_DEFAULTS = {
  full: { inputTokens: 25000, outputTokens: 6000, costUsd: 0.45 },
  replan: { inputTokens: 12000, outputTokens: 3000, costUsd: 0.20 },
  check: { inputTokens: 8000, outputTokens: 2000, costUsd: 0.05 },
  'task-replan': { inputTokens: 8000, outputTokens: 1500, costUsd: 0.04 },
  'task-generate': { inputTokens: 6000, outputTokens: 1200, costUsd: 0.03 },
  'task-command': { inputTokens: 5000, outputTokens: 1200, costUsd: 0.03 },
  // Read-only runs: a question about the registry, and 3 feature ideas for
  // one project. Both on sonnet — this is where a cheaper model shows.
  ask: { inputTokens: 7000, outputTokens: 900, costUsd: 0.04 },
  ideas: { inputTokens: 3000, outputTokens: 1300, costUsd: 0.03 },
  // Up to 40 turns of reading files and running commands inside a real repo:
  // an order of magnitude above every other run, in time and in money.
  execute: { inputTokens: 60000, outputTokens: 15000, costUsd: 2.00 }
};

function estimateRun(mode) {
  const same = readRuns().filter((r) =>
    r.mode === mode && r.status === 'ok' && ((r.inputTokens || 0) + (r.outputTokens || 0) > 0 || (r.costUsd || 0) > 0)
  ).slice(-10);
  if (same.length) {
    const avg = (k) => Math.round(same.reduce((s, r) => s + (r[k] || 0), 0) / same.length);
    return {
      inputTokens: avg('inputTokens'),
      outputTokens: avg('outputTokens'),
      costUsd: same.reduce((s, r) => s + (r.costUsd || 0), 0) / same.length,
      durationSec: avg('durationSec'),
      source: 'history'
    };
  }
  const d = EST_DEFAULTS[mode] || EST_DEFAULTS.check;
  // Seeds only: after a few runs the journal's own average takes over. full
  // and replan dropped to a minute once the digest replaced the model's own
  // file reads, so the old 7-minute seed made every morning look overdue.
  const durations = {
    full: 90, replan: 70, check: 90, 'task-replan': 100,
    'task-generate': 90, 'task-command': 80, ask: 70, ideas: 70, execute: 900
  };
  return {
    inputTokens: d.inputTokens, outputTokens: d.outputTokens, costUsd: d.costUsd,
    durationSec: durations[mode] || 120, source: 'default'
  };
}

/* Every AI run is journaled to core\ai-runs.jsonl with duration, token usage
   and cost (parsed from the CLI's json output in the run log), and status
   (ok / killed / skipped — a check that exited early on zero activity).
   The AI page reads this and can kill any currently running entry by id. */
const AI_RUNS_FILE = path.join(DATA, 'ai-runs.jsonl');

/* Everything that can go wrong with a run — a CLI that never started, a model
   that stopped at the turn limit halfway through the work, an answer file that
   was never written, a run that hangs forever — lands in ai-problems.jsonl and
   is pushed to the window as an ai:problem event. Before this, every one of
   those cases was journaled as "ok" and the user saw a run that "succeeded"
   while nothing changed. */
const AI_PROBLEMS_FILE = path.join(DATA, 'ai-problems.jsonl');
const AI_DIAG_FILE = path.join(DATA, 'ai-diagnostics.txt');

// Hard ceiling per mode (seconds). A hung claude otherwise sits in activeRuns
// forever: the spinner never stops, one of MAX_CONCURRENT_AI slots stays gone,
// and for the pipeline `pipelineRunning` stays true so no daily run ever
// starts again.
const RUN_TIMEOUT_SEC = {
  full: 900, replan: 600, check: 900, 'task-replan': 900,
  'task-generate': 900, 'task-command': 900, ask: 600, ideas: 600, execute: 3600
};

// A run is "late" (not yet dead) at 2.5x its estimate — that's what earns a
// warning toast while it is still running.
function lateAfterSec(run) {
  const est = (run.est && run.est.durationSec) || 120;
  return Math.max(90, Math.round(est * 2.5));
}

function timeoutSec(mode) { return RUN_TIMEOUT_SEC[mode] || 900; }

// Deleting the log before the run is what makes "no log" mean "the script
// died before it wrote anything" instead of "we are reading yesterday's file".
// Pipeline runs share one last-run.log, and an early exit used to make main
// re-journal the previous run's tokens and cost as a brand new run.
function freshLog(file) {
  try { fs.unlinkSync(file); } catch (e) { /* nothing to clear */ }
  return file;
}

function parseUsage(logFile, startedAt) {
  const empty = {
    inputTokens: 0, outputTokens: 0, costUsd: 0, skipped: false,
    hasLog: false, stale: false, text: '', result: null, warnings: []
  };
  let text = '';
  try {
    const st = fs.statSync(logFile);
    // 2s of slack: the script may write its first line just before we look.
    if (startedAt && st.mtimeMs < startedAt - 2000) return Object.assign({}, empty, { hasLog: true, stale: true });
    text = fs.readFileSync(logFile, 'utf8');
  } catch (e) {
    return empty;
  }
  const grab = (re) => {
    let m, last = null;
    while ((m = re.exec(text)) !== null) last = m[1];
    return last;
  };
  const num = (re) => parseInt(grab(re) || '0', 10);
  // The CLI's own result line is the only trustworthy source: is_error,
  // subtype and num_turns all live there.
  let result = null;
  const lines = text.split(/\r?\n/);
  for (let i = lines.length - 1; i >= 0; i--) {
    const s = lines[i].replace(/^﻿/, '').trim();
    if (!s.startsWith('{') || s.indexOf('"is_error"') < 0) continue;
    try { result = JSON.parse(s); break; } catch (e) { /* truncated line */ }
  }
  // input_tokens alone is ~25 on a cached run; the real input is the cache
  // read/creation counters. Without them the token tiles and every estimate
  // built from history were off by four orders of magnitude.
  const inputTokens = result && result.usage
    ? (result.usage.input_tokens || 0) + (result.usage.cache_read_input_tokens || 0) +
      (result.usage.cache_creation_input_tokens || 0)
    : num(/"input_tokens"\s*:\s*(\d+)/g) + num(/"cache_read_input_tokens"\s*:\s*(\d+)/g) +
      num(/"cache_creation_input_tokens"\s*:\s*(\d+)/g);
  return {
    inputTokens,
    outputTokens: (result && result.usage && result.usage.output_tokens) ||
      num(/"outputTokens"\s*:\s*(\d+)/g) || num(/"output_tokens"\s*:\s*(\d+)/g),
    costUsd: (result && result.total_cost_usd) ||
      parseFloat(grab(/"total_cost_usd"\s*:\s*([\d.]+)/g) || grab(/"costUSD"\s*:\s*([\d.]+)/g) || '0'),
    skipped: /^skipped:/.test(text.trim()),
    hasLog: true,
    stale: false,
    text,
    result,
    warnings: lines.filter((l) => l.indexOf('[warn]') >= 0).map((l) => l.trim())
  };
}

// Georgian, because every string the user reads in this app is Georgian.
const WARN_TEXT = [
  [/model wrote no output file/i, 'AI-მ პასუხის ფაილი საერთოდ არ ჩაწერა — ცვლილება არ შენახულა'],
  [/output file is not valid JSON/i, 'AI-ს პასუხი გატეხილი JSON იყო — ვერ ჩაიწერა'],
  [/summary file is not valid JSON/i, 'AI-ს შედეგის ფაილი გატეხილი JSON იყო'],
  [/patch apply failed/i, 'დაფის ცვლილება ვერ დაედო kanban.json-ს'],
  [/merge failed/i, 'AI-ს პასუხის ჩაწერა ჩავარდა'],
  [/comment ack failed/i, 'კომენტარზე პასუხის მონიშვნა ჩავარდა']
];

function warnText(line) {
  for (const [re, msg] of WARN_TEXT) if (re.test(line)) return msg;
  return line.replace(/^\[warn\]\s*/, '');
}

/* status: ok | skipped | killed | timeout | failed | incomplete | partial | thin
   level:  info (no toast) | warn (yellow toast) | error (red toast) */
function classifyRun(run, exitCode, usage) {
  const late = Math.round((Date.now() - run.startedAt) / 1000) > lateAfterSec(run);
  if (run.killed) return { status: 'killed', level: 'info', message: 'პროცესი შენ გათიშე.' };
  if (run.timedOut) {
    return {
      status: 'timeout', level: 'error',
      message: 'AI ' + Math.round(timeoutSec(run.mode) / 60) + ' წუთში ვერ დაასრულა და იძულებით გაითიშა.',
      detail: 'timeout after ' + timeoutSec(run.mode) + 's'
    };
  }
  if (!usage.hasLog || usage.stale) {
    return {
      status: 'failed', level: 'error',
      message: 'AI საერთოდ ვერ გაეშვა — claude CLI არ დაწერა ლოგი. შეამოწმე რომ claude დაინსტალირებულია.',
      detail: usage.stale ? 'log file is older than the run (script exited before writing)' : 'log file missing'
    };
  }
  if (usage.skipped) {
    return { status: 'skipped', level: 'info', message: usage.text.trim().split(/\r?\n/)[0] };
  }
  // The script itself gave up before reaching the model (no claude CLI, no
  // git, no folder): its own message is the most useful thing we can show.
  const fatal = /^\[fatal\]\s*(.+)$/m.exec(usage.text);
  if (fatal) {
    return {
      status: 'failed', level: 'error',
      message: 'AI ვერ გაეშვა: ' + fatal[1].trim(),
      detail: usage.text.slice(0, 800)
    };
  }
  if (exitCode) {
    return {
      status: 'failed', level: 'error',
      message: 'AI სკრიპტი შეცდომით დასრულდა (კოდი ' + exitCode + ').',
      detail: usage.text.slice(-800)
    };
  }
  if (!usage.result) {
    return {
      status: 'failed', level: 'error',
      message: 'AI-მ პასუხი არ დააბრუნა — გაშვება შუაზე გაწყდა.',
      detail: usage.text.slice(-800)
    };
  }
  if (usage.result.is_error) {
    const sub = String(usage.result.subtype || '');
    if (sub === 'error_max_turns') {
      return {
        status: 'incomplete', level: 'error',
        message: 'AI ტურების ლიმიტს (' + (usage.result.num_turns || '?') + ') მიაღწია და დავალება ბოლომდე ვერ მიიყვანა.',
        detail: (usage.result.errors || []).join('; ')
      };
    }
    return {
      status: 'failed', level: 'error',
      message: 'AI შეცდომით დასრულდა: ' + (sub || 'უცნობი შეცდომა') + '.',
      detail: (usage.result.errors || []).join('; ') || usage.text.slice(-500)
    };
  }
  if (usage.warnings.length) {
    return {
      status: 'partial', level: 'warn',
      message: warnText(usage.warnings[usage.warnings.length - 1]),
      detail: usage.warnings.join(' | ')
    };
  }
  // Ran clean but said almost nothing: an answer this short is a non-answer.
  if (usage.outputTokens > 0 && usage.outputTokens < 60) {
    return {
      status: 'thin', level: 'warn',
      message: 'AI-ს პასუხი საეჭვოდ მოკლეა (' + usage.outputTokens + ' output ტოკენი) — შეიძლება არასრული იყოს.',
      detail: 'outputTokens=' + usage.outputTokens
    };
  }
  if (late) {
    return {
      status: 'ok', level: 'warn',
      message: 'AI დაასრულა, მაგრამ მოსალოდნელზე ბევრად დიდხანს (' +
        Math.round((Date.now() - run.startedAt) / 1000) + ' წმ).',
      detail: 'expected ~' + ((run.est && run.est.durationSec) || '?') + 's'
    };
  }
  return { status: 'ok', level: 'info', message: '' };
}

// powershell.exe itself failed to launch: no log will ever exist, and without
// this the run just vanished from the UI as if it had finished.
function reportSpawnFailure(run, err) {
  const entry = {
    id: run.id, at: new Date().toISOString(), start: new Date(run.startedAt).toISOString(),
    mode: run.mode, taskId: run.taskId || null, status: 'failed', level: 'error',
    durationSec: Math.round((Date.now() - run.startedAt) / 1000),
    message: 'AI პროცესი ვერ გაეშვა (powershell): ' + ((err && err.message) || 'უცნობი შეცდომა'),
    detail: (err && err.stack) || '', logFile: run.logFile
  };
  try { fs.appendFileSync(AI_RUNS_FILE, JSON.stringify(entry) + '\n', 'utf8'); } catch (e) {}
  reportProblem(entry);
}

function reportProblem(entry) {
  try { fs.appendFileSync(AI_PROBLEMS_FILE, JSON.stringify(entry) + '\n', 'utf8'); } catch (e) {}
  if (win && !win.isDestroyed()) {
    try { win.webContents.send('ai:problem', entry); } catch (e) { /* window closing */ }
  }
}

function readProblems() {
  try {
    return fs.readFileSync(AI_PROBLEMS_FILE, 'utf8').split(/\r?\n/).filter(Boolean)
      .map((l) => { try { return JSON.parse(l); } catch (e) { return null; } }).filter(Boolean);
  } catch (e) {
    return [];
  }
}

function recordRun(run, exitCode) {
  const usage = parseUsage(run.logFile, run.startedAt);
  const verdict = classifyRun(run, exitCode || 0, usage);
  const entry = {
    id: run.id,
    start: new Date(run.startedAt).toISOString(),
    mode: run.mode,
    taskId: run.taskId || null,
    durationSec: Math.round((Date.now() - run.startedAt) / 1000),
    status: verdict.status,
    level: verdict.level,
    message: verdict.message || '',
    // A stale log belongs to an older run: never bill this one for its tokens.
    inputTokens: usage.stale ? 0 : usage.inputTokens,
    outputTokens: usage.stale ? 0 : usage.outputTokens,
    costUsd: usage.stale ? 0 : usage.costUsd,
    exitCode: exitCode || 0
  };
  try { fs.appendFileSync(AI_RUNS_FILE, JSON.stringify(entry) + '\n', 'utf8'); } catch (e) {}
  if (verdict.level !== 'info') {
    reportProblem(Object.assign({}, entry, {
      at: new Date().toISOString(),
      detail: verdict.detail || '',
      logFile: run.logFile
    }));
  }
  return entry;
}

/* Watchdog: nothing else notices a run that simply never ends. Every 5s each
   active run is checked twice — once for "this is late" (a warning while it is
   still running, so the user is not staring at a frozen spinner), once for the
   hard ceiling, where the process tree is killed like a manual cancel. */
function runWatchdog() {
  const now = Date.now();
  for (const run of activeRuns.values()) {
    const elapsed = (now - run.startedAt) / 1000;
    if (!run.lateNotified && elapsed > lateAfterSec(run)) {
      run.lateNotified = true;
      reportProblem({
        id: run.id, at: new Date().toISOString(), start: new Date(run.startedAt).toISOString(),
        mode: run.mode, taskId: run.taskId || null, status: 'slow', level: 'warn',
        durationSec: Math.round(elapsed),
        message: 'AI იგვიანებს — ' + Math.round(elapsed) + ' წმ გავიდა, მოსალოდნელი იყო ~' +
          ((run.est && run.est.durationSec) || '?') + ' წმ. ისევ მუშაობს.',
        detail: 'still running', logFile: run.logFile
      });
    }
    if (!run.timedOut && elapsed > timeoutSec(run.mode)) {
      run.timedOut = true;
      spawn('taskkill', ['/PID', String(run.pid), '/T', '/F'], PS_OPTS);
    }
  }
}
setInterval(runWatchdog, 5000);

ipcMain.handle('ai:runs', () => readRuns().slice(-100).reverse());
ipcMain.handle('ai:problems', () => readProblems().slice(-60).reverse());

/* One file to send on: every recent problem plus the tail of each log it
   points at, so a broken run can be diagnosed without opening the app. */
ipcMain.handle('ai:openDiagnostics', () => {
  const problems = readProblems().slice(-25).reverse();
  const parts = ['=== DailyBrief AI დიაგნოსტიკა · ' + new Date().toISOString() + ' ===', ''];
  if (!problems.length) parts.push('(პრობლემა არ დაფიქსირებულა)');
  const seen = new Set();
  problems.forEach((p) => {
    parts.push('--- ' + p.at + ' · ' + p.mode + ' · ' + p.status + ' (' + p.level + ') · run ' + p.id +
      (p.taskId ? ' · task ' + p.taskId : '') + ' · ' + (p.durationSec || 0) + 's');
    parts.push('    ' + (p.message || ''));
    if (p.detail) parts.push('    detail: ' + String(p.detail).replace(/\r?\n/g, ' ').slice(0, 1000));
    parts.push('');
  });
  problems.forEach((p) => {
    if (!p.logFile || seen.has(p.logFile)) return;
    seen.add(p.logFile);
    parts.push('=== LOG ' + path.basename(p.logFile) + ' (ბოლო 4000 სიმბოლო) ===');
    try { parts.push(fs.readFileSync(p.logFile, 'utf8').slice(-4000)); }
    catch (e) { parts.push('(ლოგი აღარ არსებობს)'); }
    parts.push('');
  });
  parts.push('=== ბოლო 20 გაშვება (ai-runs.jsonl) ===');
  readRuns().slice(-20).forEach((r) => parts.push(JSON.stringify(r)));
  // BOM on purpose: this file is opened in the user's text editor.
  fs.writeFileSync(AI_DIAG_FILE, '﻿' + parts.join('\r\n'), 'utf8');
  shell.openPath(AI_DIAG_FILE);
  return true;
});

// Folder scanner: baseline snapshot for a task's linked folder (git-aware).
const SCAN_SCRIPT = path.join(CORE_DIR, 'scan-folder.ps1');

ipcMain.handle('task:scan', (ev, taskId, dir) => {
  if (!taskId || !dir) return false;
  spawn('powershell.exe', [
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
    '-File', SCAN_SCRIPT, '-TaskId', String(taskId).slice(0, 60), '-Dir', String(dir).slice(0, 500)
  ], PS_OPTS);
  return true;
});

// Open the most relevant run's assembled context as a TXT for inspection:
// whichever run started most recently, active or not.
ipcMain.handle('ai:openContext', () => {
  const running = Array.from(activeRuns.values()).pop();
  const last = readRuns().slice(-1)[0] || {};
  const mode = (running && running.mode) || last.mode || 'check';
  const runId = (running && running.id) || last.id || '';
  const promptFiles = {
    full: 'prompt.md', replan: 'prompt-replan.md',
    check: 'prompt-check.md', 'task-replan': 'prompt-task-replan.md',
    'task-generate': 'prompt-task-generate.md', 'task-command': 'prompt-task-command.md',
    ask: 'prompt-ask.md', ideas: 'prompt-ideas.md', execute: 'prompt-execute.md'
  };
  const pf = promptFiles[mode] || 'prompt-check.md';
  const parts = ['=== რეჟიმი: ' + mode + ' ===', ''];
  parts.push('=== PROMPT (' + pf + ') ===');
  try { parts.push(fs.readFileSync(path.join(CORE_DIR, pf), 'utf8')); }
  catch (e) { parts.push('(ფაილი ვერ მოიძებნა)'); }
  if (mode === 'execute') {
    // No digest file: the brief is assembled from the task card itself and
    // handed to the model on stdin, inside the project folder.
    parts.push('', '=== რისგან შედგება ბრიფი ===',
      'ტასკის სათაური · აღწერა · ჩეკლისტი · ბოლო კომენტარები · მიბმული ფოლდერი · branch');
  } else if (mode !== 'full' && mode !== 'replan') {
    // ask/ideas keep their own digest files so a question and a check that
    // happen to share a run id can never overwrite each other.
    const dPrefix = (mode === 'ask' || mode === 'ideas') ? 'ask-digest-' : 'check-digest-';
    const digestName = runId ? `${dPrefix}${runId}.json` : 'check-digest.json';
    parts.push('', '=== ' + digestName + ' — ზუსტად ეს მიეწოდა AI-ს ===');
    try { parts.push(fs.readFileSync(path.join(DATA, digestName), 'utf8')); }
    catch (e) { parts.push('(digest ჯერ არ არსებობს)'); }
  } else {
    parts.push('', '=== წყარო ფაილები, რომლებსაც AI კითხულობს ===',
      'GOALS.md · STATE.md · PROGRESS.md · top-dirs.txt · snapshots/ (ბოლო 3 დღე) · briefings/ (ბოლო 1) · kanban.json');
  }
  const out = path.join(DATA, 'last-ai-context.txt');
  // BOM on purpose: this file is for the user's text editor.
  fs.writeFileSync(out, '﻿' + parts.join('\r\n'), 'utf8');
  shell.openPath(out);
  return true;
});

// Cancel one specific run by id — several may be active at once.
ipcMain.handle('ai:kill', (ev, runId) => {
  const run = activeRuns.get(String(runId || ''));
  if (!run) return false;
  run.killed = true;
  // Kill the whole tree: powershell -> claude.cmd -> node.
  spawn('taskkill', ['/PID', String(run.pid), '/T', '/F'], PS_OPTS);
  return true;
});

ipcMain.handle('ai:status', () => Array.from(activeRuns.values()).map((r) => ({
  id: r.id, mode: r.mode, taskId: r.taskId || null, startedAt: r.startedAt, est: r.est
})));

// taskId/replan/generate: which check-family flavor to run. Concurrent with
// each other (capped at MAX_CONCURRENT_AI), always exclusive with the daily
// pipeline (full/replan) since that rewrites kanban.json wholesale.
function runCheck(taskId, replan, generate, command, taskIds) {
  if (pipelineRunning || activeRuns.size >= MAX_CONCURRENT_AI) return false;
  const mode = command ? 'task-command'
    : (generate ? 'task-generate' : (replan ? 'task-replan' : 'check'));
  const id = crypto.randomUUID().slice(0, 8);
  const args = [
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
    '-File', CHECK_SCRIPT, '-RunId', id
  ];
  if (taskId) args.push('-TaskId', taskId);
  if (!taskId && taskIds && taskIds.length) args.push('-TaskIds', taskIds.join(','));
  if (replan) args.push('-Replan');
  if (generate) args.push('-Generate');
  if (command) args.push('-Command');
  const logFile = freshLog(path.join(DATA, `check-run-${id}.log`));
  const ps = spawn('powershell.exe', args, PS_OPTS);
  const run = {
    id, mode, taskId: taskId || null, pid: ps.pid, startedAt: Date.now(),
    logFile,
    killed: false, exclusive: false, est: estimateRun(mode)
  };
  activeRuns.set(id, run);
  broadcastAiStatus();
  ps.on('error', (err) => { activeRuns.delete(id); reportSpawnFailure(run, err); broadcastAiStatus(); });
  ps.on('exit', async (code) => {
    activeRuns.delete(id);
    recordRun(run, code);
    broadcastAiStatus();
    try { syncFilesToDb(); } catch (e) { /* file fallback still works */ }
    // A comment may have asked for the work itself, not just a new plan.
    if (mode === 'task-command') { try { consumeExecuteRequest(); } catch (e) {} }
    scheduleReload();
  });
  return true;
}

/* Ask + ideas (core\ask.ps1). Both are read-only: they never rewrite
   kanban.json, so they may run alongside the daily pipeline, and they never
   trigger a page reload — a reload mid-question would wipe whatever the user
   is typing. The renderer gets an ask:updated / ideas:updated event instead
   and repaints one list. */

function runAsk(mode, dir) {
  if (activeRuns.size >= MAX_CONCURRENT_AI) return false;
  const id = crypto.randomUUID().slice(0, 8);
  const args = [
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
    '-File', ASK_SCRIPT, '-Mode', mode, '-RunId', id
  ];
  if (dir) args.push('-Dir', String(dir).slice(0, 500));
  const logFile = freshLog(path.join(DATA, `ask-run-${id}.log`));
  const ps = spawn('powershell.exe', args, PS_OPTS);
  const run = {
    id, mode, taskId: null, pid: ps.pid, startedAt: Date.now(),
    logFile,
    killed: false, exclusive: false, est: estimateRun(mode)
  };
  activeRuns.set(id, run);
  broadcastAiStatus();
  const finish = () => {
    activeRuns.delete(id);
    broadcastAiStatus();
    if (win && !win.isDestroyed()) {
      try { win.webContents.send(mode === 'ideas' ? 'ideas:updated' : 'ask:updated'); } catch (e) {}
    }
  };
  ps.on('error', (err) => { reportSpawnFailure(run, err); finish(); });
  ps.on('exit', (code) => { recordRun(run, code); finish(); });
  return true;
}

/* Execute: the one run with Bash and Edit inside a real repository. The
   script itself refuses a folder without git and moves to its own
   dailybrief/<taskid> branch before the model starts, so everything it does
   is one `git checkout -` away from gone. It never commits. */

function runExecute(taskId) {
  const id = String(taskId || '').slice(0, 60);
  if (!id) return false;
  if (activeRuns.size >= MAX_CONCURRENT_AI) return false;
  // One execution at a time: two models editing the same working tree (or
  // fighting over the branch) is not a state worth debugging.
  for (const r of activeRuns.values()) if (r.mode === 'execute') return false;
  const runId = crypto.randomUUID().slice(0, 8);
  const logFile = freshLog(path.join(DATA, `execute-run-${runId}.log`));
  const ps = spawn('powershell.exe', [
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
    '-File', EXECUTE_SCRIPT, '-TaskId', id, '-RunId', runId
  ], PS_OPTS);
  const run = {
    id: runId, mode: 'execute', taskId: id, pid: ps.pid, startedAt: Date.now(),
    logFile,
    killed: false, exclusive: false, est: estimateRun('execute')
  };
  activeRuns.set(runId, run);
  broadcastAiStatus();
  ps.on('error', (err) => { activeRuns.delete(runId); reportSpawnFailure(run, err); broadcastAiStatus(); });
  ps.on('exit', (code) => {
    activeRuns.delete(runId);
    recordRun(run, code);
    broadcastAiStatus();
    try { syncFilesToDb(); } catch (e) { /* files still serve as fallback */ }
    scheduleReload();
  });
  return true;
}

ipcMain.handle('task:execute', (ev, taskId) => runExecute(taskId));

/* A comment can order the work itself ("გააკეთე"), not just a re-plan. The
   board run has no tools for that, so it writes execute-request.json and we
   pick it up here, the moment that run exits. */
function consumeExecuteRequest() {
  const req = readJson(EXECUTE_REQUEST_FILE);
  try { fs.unlinkSync(EXECUTE_REQUEST_FILE); } catch (e) { /* already gone */ }
  if (req && req.taskId) runExecute(req.taskId);
}

function readAskLog() {
  const data = readJson(ASK_LOG_FILE);
  return data && Array.isArray(data.messages) ? data.messages : [];
}

function writeAskLog(messages) {
  try {
    fs.writeFileSync(ASK_LOG_FILE, JSON.stringify({ messages: messages.slice(-60) }, null, 2), 'utf8');
  } catch (e) { /* the thread is a convenience, never block the run on it */ }
}

ipcMain.handle('ask:load', () => readAskLog());

// The question is written to the thread here, not passed as an argument:
// PS 5.1 mangles quotes inside an argument, and the script reads the last
// user message out of ask-log.json anyway.
ipcMain.handle('ask:send', (ev, text, dir) => {
  const q = String(text || '').trim().slice(0, 1000);
  if (!q) return { messages: readAskLog(), started: false };
  const messages = readAskLog();
  messages.push({
    id: 'q' + crypto.randomUUID().slice(0, 8),
    by: 'user', at: new Date().toISOString(),
    text: q, dir: String(dir || '')
  });
  writeAskLog(messages);
  const started = runAsk('ask', dir ? String(dir) : '');
  return { messages: readAskLog(), started };
});

ipcMain.handle('ask:clear', () => { writeAskLog([]); return true; });

function readIdeas() {
  const data = readJson(IDEAS_FILE);
  return {
    entries: data && Array.isArray(data.entries) ? data.entries : [],
    declined: data && Array.isArray(data.declined) ? data.declined : [],
    accepted: data && Array.isArray(data.accepted) ? data.accepted : []
  };
}

// A card always shows three undecided ideas. Deciding one empties a slot, so
// the moment it does, a refill run starts for that folder.
function pendingIdeas(entry) {
  const ideas = entry && Array.isArray(entry.ideas) ? entry.ideas : [];
  return ideas.filter((i) => i && i.state === 'new');
}

function writeIdeas(store) {
  try { fs.writeFileSync(IDEAS_FILE, JSON.stringify(store, null, 2), 'utf8'); } catch (e) {}
}

ipcMain.handle('ideas:load', () => {
  const store = readIdeas();
  const ig = readIgnore();
  return {
    entries: store.entries.filter((e) => !isIgnored(e && e.dir, ig)),
    declined: store.declined,
    accepted: store.accepted
  };
});

ipcMain.handle('ideas:generate', (ev, dir) => (dir ? runAsk('ideas', String(dir)) : false));

/* Accept -> the renderer has already created the task and passes its id back,
   so the accepted title is remembered (the model must never propose it again)
   and the idea leaves the card: a decided suggestion is not a suggestion.
   Decline -> same, into the declined list. Either way the card drops below
   three, so a refill run starts right here and the card fills itself back up. */
ipcMain.handle('ideas:decide', (ev, dir, ideaId, state, taskId) => {
  const store = readIdeas();
  const d = String(dir || '').toLowerCase();
  const id = String(ideaId || '');
  const accepted = state === 'accepted';
  const at = new Date().toISOString();
  store.entries.forEach((e) => {
    if (String((e && e.dir) || '').toLowerCase() !== d) return;
    const ideas = Array.isArray(e.ideas) ? e.ideas : [];
    ideas.forEach((i) => {
      if (!i || String(i.id) !== id) return;
      const rec = { dir: e.dir, title: String(i.title || ''), at };
      if (accepted) store.accepted.push(Object.assign({ taskId: String(taskId || '') }, rec));
      else store.declined.push(rec);
    });
    e.ideas = ideas.filter((i) => !i || String(i.id) !== id);
  });
  store.declined = store.declined.slice(-300);
  store.accepted = store.accepted.slice(-300);
  writeIdeas(store);
  const entry = store.entries.find((e) => String((e && e.dir) || '').toLowerCase() === d);
  const refilling = pendingIdeas(entry).length < 3 ? runAsk('ideas', String(dir || '')) : false;
  return Object.assign({ refilling }, store);
});

/* Analytics: raw file-change events collected by core\monitor.ps1 (no AI)
   plus daily project scores from the activity snapshots. Aggregation happens
   in the renderer; this just reads the last 7 days. */

function last7Dates() {
  const out = [];
  for (let i = 6; i >= 0; i--) {
    const d = new Date(Date.now() - i * 86400000);
    out.push(d.getFullYear() + '-' +
      String(d.getMonth() + 1).padStart(2, '0') + '-' +
      String(d.getDate()).padStart(2, '0'));
  }
  return out;
}

ipcMain.handle('analytics:data', () => {
  const days = last7Dates();
  const events = [];
  const seen = new Set();
  const ig = readIgnore();
  days.forEach((date) => {
    const f = path.join(ANALYTICS_DIR, date + '.jsonl');
    if (!fs.existsSync(f)) return;
    fs.readFileSync(f, 'utf8').replace(/^﻿/, '').split(/\r?\n/).forEach((line) => {
      line = line.trim();
      if (!line) return;
      try {
        const e = JSON.parse(line);
        // Overlapping monitor windows re-log the same change: dedupe.
        if (isIgnored(e.project, ig)) return;
        const key = (e.project || '') + '|' + (e.file || '') + '|' + (e.ts || '');
        if (seen.has(key)) return;
        seen.add(key);
        events.push({ ts: e.ts, project: e.project, file: e.file });
      } catch (err) { /* skip malformed line */ }
    });
  });
  const daily = [];
  days.forEach((date) => {
    const f = path.join(SNAP_DIR, 'activity-' + date + '.txt');
    if (!fs.existsSync(f)) return;
    fs.readFileSync(f, 'utf8').split(/\r?\n/).forEach((line) => {
      const m = line.match(/^\s*([\d.,]+)\s+(.+)$/);
      if (m && !isIgnored(m[2].trim(), ig)) {
        daily.push({ date, score: parseFloat(m[1].replace(',', '.')), project: m[2].trim() });
      }
    });
  });
  return { days, events, daily };
});

let monitorRunning = false;

function runMonitor() {
  if (monitorRunning) return;
  monitorRunning = true;
  const ps = spawn('powershell.exe', [
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
    '-File', MONITOR_SCRIPT
  ], PS_OPTS);
  ps.on('error', () => { monitorRunning = false; });
  ps.on('exit', () => { monitorRunning = false; });
}

/* ---------- window & pipeline ---------- */

function createWindow() {
  win = new BrowserWindow({
    width: 1140,
    height: 1000,
    minWidth: 760,
    autoHideMenuBar: true,
    backgroundColor: '#15181E',
    icon: ICON,
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false
    }
  });
  wireZoom(win);
  win.loadFile(PAGE);
}

function runPipeline(force) {
  if (pipelineRunning || activeRuns.size > 0) return;
  pipelineRunning = true;
  const mode = force ? 'replan' : 'full';
  const id = 'pipeline';
  // -NoShow: the Electron window is the UI; skip the legacy WPF popup.
  // -Force (replan): regenerate today's briefing taking done-state into account.
  const args = [
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
    '-File', PIPELINE, '-NoShow'
  ];
  if (force) args.push('-Force');
  const logFile = freshLog(path.join(DATA, 'last-run.log'));
  const ps = spawn('powershell.exe', args, PS_OPTS);
  const run = {
    id, mode, taskId: null, pid: ps.pid, startedAt: Date.now(),
    logFile,
    killed: false, exclusive: true, est: estimateRun(mode)
  };
  activeRuns.set(id, run);
  broadcastAiStatus();
  ps.on('error', (err) => {
    pipelineRunning = false; activeRuns.delete(id); reportSpawnFailure(run, err); broadcastAiStatus();
  });
  ps.on('exit', async (code) => {
    pipelineRunning = false;
    activeRuns.delete(id);
    recordRun(run, code);
    broadcastAiStatus();
    try { syncFilesToDb(); } catch (e) { /* files still serve as fallback */ }
    scheduleReload();
  });
}

/* ---------- auto-update (GitHub releases) ---------- */

// electron-updater reads the publish block in package.json and the latest.yml
// that electron-builder uploads with each release. Only a packaged build can
// update itself, so in dev every entry point reports "dev" and does nothing.
let autoUpdater = null;
let updateState = { status: 'idle', version: null, message: '', percent: 0 };

function sendUpdateState() {
  if (win && !win.isDestroyed()) {
    try { win.webContents.send('update:state', updateState); } catch (e) { /* window closing */ }
  }
}

function setUpdateState(status, extra) {
  updateState = Object.assign({ status, version: null, message: '', percent: 0 }, extra || {});
  sendUpdateState();
}

function initUpdater() {
  if (!app.isPackaged) { setUpdateState('dev', { message: 'განახლება მხოლოდ დაინსტალირებულ ვერსიაშია' }); return; }
  try {
    autoUpdater = require('electron-updater').autoUpdater;
  } catch (e) {
    setUpdateState('error', { message: 'electron-updater ვერ ჩაიტვირთა' });
    return;
  }
  autoUpdater.autoDownload = true;
  autoUpdater.autoInstallOnAppQuit = true;
  autoUpdater.on('checking-for-update', () => setUpdateState('checking'));
  autoUpdater.on('update-available', (info) => setUpdateState('downloading', { version: info && info.version }));
  autoUpdater.on('update-not-available', () => setUpdateState('current', { version: app.getVersion() }));
  autoUpdater.on('download-progress', (p) => setUpdateState('downloading', {
    version: updateState.version, percent: Math.round((p && p.percent) || 0)
  }));
  autoUpdater.on('update-downloaded', (info) => setUpdateState('ready', { version: info && info.version, percent: 100 }));
  autoUpdater.on('error', (err) => setUpdateState('error', { message: String((err && err.message) || err).slice(0, 300) }));
}

function checkForUpdates(manual) {
  if (!autoUpdater) {
    if (manual) sendUpdateState();
    return false;
  }
  const settings = Object.assign({}, DEFAULT_SETTINGS, kvGet('settings') || {});
  if (!manual && !settings.autoUpdate) return false;
  autoUpdater.autoDownload = manual || settings.autoUpdate;
  autoUpdater.checkForUpdates().catch((err) => {
    setUpdateState('error', { message: String((err && err.message) || err).slice(0, 300) });
  });
  return true;
}

ipcMain.handle('update:check', () => checkForUpdates(true));
ipcMain.handle('update:state', () => updateState);
ipcMain.handle('update:install', () => {
  if (!autoUpdater || updateState.status !== 'ready') return false;
  // quitAndInstall closes every window itself; the app-quit handlers still run.
  setImmediate(() => autoUpdater.quitAndInstall(false, true));
  return true;
});

/* Daily trajectory pass: propose new tasks from the project registry once a
   day. It used to be a button only, so on quiet days the board just aged. */
function maybeDailyGenerate() {
  const settings = Object.assign({}, DEFAULT_SETTINGS, kvGet('settings') || {});
  if (!settings.autoGenerate) return;
  const today = new Date().toISOString().slice(0, 10);
  if ((kvGet('lastGenerate') || {}).date === today) return;
  kvSet('lastGenerate', { date: today });
  runCheck('', false, true);
}

/* Feature ideas age with the project. A card is refilled when it holds fewer
   than three undecided suggestions (a decision usually refills it on the spot;
   this catches the ones whose refill run never got a slot), or when every
   suggestion has been decided and the project has actually moved since the
   card was filled (new commit, different dirty count, more changed files).
   Capped at 3 projects a day, spread out so they don't take the whole
   concurrency pool. */
function maybeRefreshIdeas() {
  const settings = Object.assign({}, DEFAULT_SETTINGS, kvGet('settings') || {});
  if (!settings.autoIdeas) return;
  const today = new Date().toISOString().slice(0, 10);
  if ((kvGet('lastIdeas') || {}).date === today) return;
  const reg = readJson(PROJECTS_FILE);
  if (!reg || !Array.isArray(reg.projects)) return;
  const ig = readIgnore();
  const sig = (p) => `${p.lastCommitAt || ''}|${p.dirtyCount || 0}|${p.changed14d || 0}`;
  const stale = readIdeas().entries.filter((e) => {
    if (!e || !e.dir || isIgnored(e.dir, ig)) return false;
    if (pendingIdeas(e).length < 3) return true;
    const p = reg.projects.find((x) => String((x && x.dir) || '').toLowerCase() === String(e.dir).toLowerCase());
    return !!p && sig(p) !== String(e.signature || '');
  }).slice(0, 3);
  if (!stale.length) return;
  kvSet('lastIdeas', { date: today });
  stale.forEach((e, i) => setTimeout(() => runAsk('ideas', e.dir), i * 90 * 1000));
}

app.whenReady().then(() => {
  // Window first — Mongo connects in the background; IPC handlers fall back
  // to files until it's ready, so startup never waits on the database.
  createWindow();
  initDb();
  runPipeline();
  // Prune once at startup and once a day after: run files pile up fastest on
  // a long-running instance, and deleting them costs nothing.
  pruneRunFiles();
  setInterval(pruneRunFiles, 24 * 60 * 60 * 1000);
  // Auto status check for kanban tasks every 5 hours.
  setInterval(() => runCheck('', false, false, false), 5 * 60 * 60 * 1000);
  // Background activity monitor (no AI): on startup and every 30 minutes.
  runMonitor();
  setInterval(runMonitor, 30 * 60 * 1000);
  // Project registry (no AI): same cadence, slightly offset so the two scans
  // don't fight over the disk on startup.
  setTimeout(runDiscover, 20 * 1000);
  setInterval(runDiscover, 30 * 60 * 1000);
  // Auto-update: check shortly after launch, then every 6 hours.
  initUpdater();
  setTimeout(() => checkForUpdates(false), 30 * 1000);
  setInterval(() => checkForUpdates(false), 6 * 60 * 60 * 1000);
  // One trajectory pass per day, after the registry has been refreshed.
  setTimeout(maybeDailyGenerate, 3 * 60 * 1000);
  // Refill the feature-idea cards of projects that moved since they were filled.
  setTimeout(maybeRefreshIdeas, 6 * 60 * 1000);
  // Reload when the pipeline (or anything else) rewrites the page file.
  fs.watchFile(PAGE, { interval: 5000 }, (curr, prev) => {
    if (curr.mtimeMs !== prev.mtimeMs && win && !win.isDestroyed()) win.reload();
  });
});

app.on('window-all-closed', () => {
  kvClose();
  app.quit();
});
