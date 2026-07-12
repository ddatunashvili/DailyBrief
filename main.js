// DailyBrief Electron shell.
// Opens brief-app.html in an app window and kicks off the daily pipeline
// (core\daily-brief.ps1) hidden in the background. When the pipeline rewrites
// brief-app.html (new BRIEF data), the window reloads automatically.
//
// Storage: local MongoDB (db "dailybrief", collections "briefs" and "done").
// The pipeline still works through files — core\briefs\*.json (extracted from
// the BRIEF block) and core\done\*.json (what Claude reads next morning) — so
// files are synced into Mongo on start and after each pipeline run, and every
// done-save is mirrored back to disk. If MongoDB is down, the app falls back
// to files and keeps working.

const { app, BrowserWindow, ipcMain, dialog, shell } = require('electron');
const { spawn } = require('child_process');
const path = require('path');
const fs = require('fs');

// The packaged exe runs from output\win-unpacked, but the live project
// (page, core, pipeline) stays at the project root so Claude's daily
// edits keep reaching the running app.
const ROOT = app.isPackaged
  ? 'C:\\Users\\davit\\OneDrive\\Desktop\\DailyBriefApp'
  : __dirname;

const PAGE = path.join(ROOT, 'brief-app.html');
const PIPELINE = path.join(ROOT, 'core', 'daily-brief.ps1');
const BRIEFS_DIR = path.join(ROOT, 'core', 'briefs');
const LEGACY_DIR = path.join(ROOT, 'core', 'briefings');
const DONE_DIR = path.join(ROOT, 'core', 'done');
const PLANS_FILE = path.join(ROOT, 'core', 'plans.json');
const KANBAN_FILE = path.join(ROOT, 'core', 'kanban.json');
const CHECK_SCRIPT = path.join(ROOT, 'core', 'kanban-check.ps1');
const MONITOR_SCRIPT = path.join(ROOT, 'core', 'monitor.ps1');
const ANALYTICS_DIR = path.join(ROOT, 'core', 'analytics');
const SNAP_DIR = path.join(ROOT, 'core', 'snapshots');
const ICON = path.join(ROOT, 'build', 'icon.png');

// Own embedded database: SQLite file next to the data (no external server).
const DB_FILE = path.join(ROOT, 'core', 'dailybrief.db');

const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;

let win = null;
let db = null;

// Second launch (e.g. logon task while app already open): focus the existing window.
if (!app.requestSingleInstanceLock()) {
  app.quit();
} else {
  app.on('second-instance', () => {
    if (win && !win.isDestroyed()) {
      if (win.isMinimized()) win.restore();
      win.focus();
    }
  });
}

/* ---------- file helpers ---------- */

function listDates(dir, ext) {
  try {
    return fs.readdirSync(dir)
      .filter((f) => f.endsWith(ext) && DATE_RE.test(f.slice(0, 10)))
      .map((f) => f.slice(0, 10));
  } catch (e) {
    return [];
  }
}

function readJson(file) {
  try {
    // PS 5.1 tools write UTF-8 with BOM — strip it before parsing.
    return JSON.parse(fs.readFileSync(file, 'utf8').replace(/^﻿/, ''));
  } catch (e) {
    return null;
  }
}

/* ---------- SQLite (embedded, core\dailybrief.db) ---------- */

function initDb() {
  try {
    const Database = require('better-sqlite3');
    db = new Database(DB_FILE);
    db.pragma('journal_mode = WAL');
    db.exec('CREATE TABLE IF NOT EXISTS kv (key TEXT PRIMARY KEY, value TEXT NOT NULL)');
    syncFilesToDb();
  } catch (e) {
    db = null; // SQLite unavailable (e.g. ABI mismatch): file fallback keeps working
  }
}

function kvGet(key) {
  if (!db) return null;
  try {
    const row = db.prepare('SELECT value FROM kv WHERE key = ?').get(key);
    return row ? JSON.parse(row.value) : null;
  } catch (e) { return null; }
}

function kvSet(key, obj) {
  if (!db) return;
  try {
    db.prepare('INSERT INTO kv (key, value) VALUES (?, ?) ' +
      'ON CONFLICT(key) DO UPDATE SET value = excluded.value')
      .run(key, JSON.stringify(obj));
  } catch (e) { /* file mirror still persists it */ }
}

function kvKeys(prefix) {
  if (!db) return [];
  try {
    return db.prepare("SELECT key FROM kv WHERE key LIKE ? || '%'").all(prefix)
      .map((r) => r.key.slice(prefix.length));
  } catch (e) { return []; }
}

function syncFilesToDb() {
  if (!db) return;
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
  if (pipelineRunning) return false;
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

const KANBAN_STATUSES = ['urgent', 'important', 'planning', 'delayed'];

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
      comments: (Array.isArray(t && t.comments) ? t.comments : []).slice(0, 100).map((c) => ({
        by: (c && c.by) === 'ai' ? 'ai' : 'user',
        text: String(c && c.text || '').slice(0, 1000),
        at: (c && c.at) || now
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
      })).filter((s) => s.text)
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
  return true;
});

ipcMain.handle('kanban:check', () => {
  if (checkRunning || pipelineRunning) return false;
  runCheck();
  return true;
});

ipcMain.handle('kanban:taskCheck', (ev, taskId) => {
  if (checkRunning || pipelineRunning || !taskId) return false;
  runCheck(String(taskId).slice(0, 60), false);
  return true;
});

ipcMain.handle('kanban:taskReplan', (ev, taskId) => {
  if (checkRunning || pipelineRunning || !taskId) return false;
  runCheck(String(taskId).slice(0, 60), true);
  return true;
});

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

let checkRunning = false;

/* AI activity state: drives the bottom progress popup in the renderer.
   Broadcast on change and queryable, so it survives page reloads.
   `est` is the upfront token/cost estimate for the run: the average of past
   successful runs of the same mode, or a static default before any history. */
let aiState = { running: false, mode: null, startedAt: null, est: null };

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
  'task-replan': { inputTokens: 8000, outputTokens: 1500, costUsd: 0.04 }
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
  const durations = { full: 420, replan: 240, check: 90, 'task-replan': 100 };
  return {
    inputTokens: d.inputTokens, outputTokens: d.outputTokens, costUsd: d.costUsd,
    durationSec: durations[mode] || 120, source: 'default'
  };
}

/* Every AI run is journaled to core\ai-runs.jsonl with duration, token usage
   and cost (parsed from the CLI's json output in the run log), and status
   (ok / killed). The AI page reads this and can kill the current run. */
const AI_RUNS_FILE = path.join(ROOT, 'core', 'ai-runs.jsonl');
let currentRun = null; // { pid, mode, startedAt, logFile, killed }

function parseUsage(logFile) {
  try {
    const text = fs.readFileSync(logFile, 'utf8');
    const grab = (re) => {
      let m, last = null;
      while ((m = re.exec(text)) !== null) last = m[1];
      return last;
    };
    return {
      inputTokens: parseInt(grab(/"inputTokens"\s*:\s*(\d+)/g) || grab(/"input_tokens"\s*:\s*(\d+)/g) || '0', 10),
      outputTokens: parseInt(grab(/"outputTokens"\s*:\s*(\d+)/g) || grab(/"output_tokens"\s*:\s*(\d+)/g) || '0', 10),
      costUsd: parseFloat(grab(/"costUSD"\s*:\s*([\d.]+)/g) || grab(/"total_cost_usd"\s*:\s*([\d.]+)/g) || '0')
    };
  } catch (e) {
    return { inputTokens: 0, outputTokens: 0, costUsd: 0 };
  }
}

function recordRun(run) {
  const usage = parseUsage(run.logFile);
  const entry = {
    start: new Date(run.startedAt).toISOString(),
    mode: run.mode,
    durationSec: Math.round((Date.now() - run.startedAt) / 1000),
    status: run.killed ? 'killed' : 'ok',
    inputTokens: usage.inputTokens,
    outputTokens: usage.outputTokens,
    costUsd: usage.costUsd
  };
  try { fs.appendFileSync(AI_RUNS_FILE, JSON.stringify(entry) + '\n', 'utf8'); } catch (e) {}
}

ipcMain.handle('ai:runs', () => readRuns().slice(-100).reverse());

// Folder scanner: baseline snapshot for a task's linked folder (git-aware).
const SCAN_SCRIPT = path.join(ROOT, 'core', 'scan-folder.ps1');

ipcMain.handle('task:scan', (ev, taskId, dir) => {
  if (!taskId || !dir) return false;
  spawn('powershell.exe', [
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
    '-File', SCAN_SCRIPT, '-TaskId', String(taskId).slice(0, 60), '-Dir', String(dir).slice(0, 500)
  ], { windowsHide: true, stdio: 'ignore' });
  return true;
});

// Open the last run's assembled context as a TXT for inspection.
ipcMain.handle('ai:openContext', () => {
  const mode = (currentRun && currentRun.mode) || (readRuns().slice(-1)[0] || {}).mode || 'check';
  const promptFiles = {
    full: 'prompt.md', replan: 'prompt-replan.md',
    check: 'prompt-check.md', 'task-replan': 'prompt-task-replan.md'
  };
  const pf = promptFiles[mode] || 'prompt-check.md';
  const parts = ['=== რეჟიმი: ' + mode + ' ===', ''];
  parts.push('=== PROMPT (' + pf + ') ===');
  try { parts.push(fs.readFileSync(path.join(ROOT, 'core', pf), 'utf8')); }
  catch (e) { parts.push('(ფაილი ვერ მოიძებნა)'); }
  if (mode === 'check' || mode === 'task-replan') {
    parts.push('', '=== check-digest.json — ზუსტად ეს მიეწოდა AI-ს ===');
    try { parts.push(fs.readFileSync(path.join(ROOT, 'core', 'check-digest.json'), 'utf8')); }
    catch (e) { parts.push('(digest ჯერ არ არსებობს)'); }
  } else {
    parts.push('', '=== წყარო ფაილები, რომლებსაც AI კითხულობს ===',
      'GOALS.md · STATE.md · PROGRESS.md · top-dirs.txt · snapshots/ (ბოლო 3 დღე) · briefings/ (ბოლო 1) · kanban.json');
  }
  const out = path.join(ROOT, 'core', 'last-ai-context.txt');
  // BOM on purpose: this file is for the user's text editor.
  fs.writeFileSync(out, '﻿' + parts.join('\r\n'), 'utf8');
  shell.openPath(out);
  return true;
});

ipcMain.handle('ai:kill', () => {
  if (!currentRun) return false;
  currentRun.killed = true;
  // Kill the whole tree: powershell -> claude.cmd -> node.
  spawn('taskkill', ['/PID', String(currentRun.pid), '/T', '/F'], { windowsHide: true, stdio: 'ignore' });
  return true;
});

function setAiState(mode) {
  aiState = mode
    ? { running: true, mode, startedAt: Date.now(), est: estimateRun(mode) }
    : { running: false, mode: null, startedAt: null, est: null };
  if (win && !win.isDestroyed()) {
    try { win.webContents.send('ai:status', aiState); } catch (e) { /* window closing */ }
  }
}

ipcMain.handle('ai:status', () => aiState);

function runCheck(taskId, replan) {
  if (checkRunning) return;
  checkRunning = true;
  const mode = replan ? 'task-replan' : 'check';
  setAiState(mode);
  const args = [
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
    '-File', CHECK_SCRIPT
  ];
  if (taskId) args.push('-TaskId', taskId);
  if (replan) args.push('-Replan');
  const ps = spawn('powershell.exe', args, { windowsHide: true, stdio: 'ignore' });
  currentRun = { pid: ps.pid, mode, startedAt: Date.now(), logFile: path.join(ROOT, 'core', 'check-run.log'), killed: false };
  ps.on('error', () => { checkRunning = false; currentRun = null; setAiState(null); });
  ps.on('exit', async () => {
    checkRunning = false;
    if (currentRun) { recordRun(currentRun); currentRun = null; }
    setAiState(null);
    try { syncFilesToDb(); } catch (e) { /* file fallback still works */ }
    if (win && !win.isDestroyed()) win.reload();
  });
}

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
  days.forEach((date) => {
    const f = path.join(ANALYTICS_DIR, date + '.jsonl');
    if (!fs.existsSync(f)) return;
    fs.readFileSync(f, 'utf8').replace(/^﻿/, '').split(/\r?\n/).forEach((line) => {
      line = line.trim();
      if (!line) return;
      try {
        const e = JSON.parse(line);
        // Overlapping monitor windows re-log the same change: dedupe.
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
      if (m) daily.push({ date, score: parseFloat(m[1].replace(',', '.')), project: m[2].trim() });
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
  ], { windowsHide: true, stdio: 'ignore' });
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
  win.loadFile(PAGE);
}

let pipelineRunning = false;

function runPipeline(force) {
  if (pipelineRunning) return;
  pipelineRunning = true;
  setAiState(force ? 'replan' : 'full');
  // -NoShow: the Electron window is the UI; skip the legacy WPF popup.
  // -Force (replan): regenerate today's briefing taking done-state into account.
  const args = [
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
    '-File', PIPELINE, '-NoShow'
  ];
  if (force) args.push('-Force');
  const ps = spawn('powershell.exe', args, { windowsHide: true, stdio: 'ignore' });
  currentRun = { pid: ps.pid, mode: force ? 'replan' : 'full', startedAt: Date.now(), logFile: path.join(ROOT, 'core', 'last-run.log'), killed: false };
  ps.on('error', () => { pipelineRunning = false; currentRun = null; setAiState(null); });
  ps.on('exit', async () => {
    pipelineRunning = false;
    if (currentRun) { recordRun(currentRun); currentRun = null; }
    setAiState(null);
    try { syncFilesToDb(); } catch (e) { /* files still serve as fallback */ }
    if (win && !win.isDestroyed()) win.reload();
  });
}

app.whenReady().then(() => {
  // Window first — Mongo connects in the background; IPC handlers fall back
  // to files until it's ready, so startup never waits on the database.
  createWindow();
  initDb();
  runPipeline();
  // Auto status check for kanban tasks every 5 hours.
  setInterval(runCheck, 5 * 60 * 60 * 1000);
  // Background activity monitor (no AI): on startup and every 30 minutes.
  runMonitor();
  setInterval(runMonitor, 30 * 60 * 1000);
  // Reload when the pipeline (or anything else) rewrites the page file.
  fs.watchFile(PAGE, { interval: 5000 }, (curr, prev) => {
    if (curr.mtimeMs !== prev.mtimeMs && win && !win.isDestroyed()) win.reload();
  });
});

app.on('window-all-closed', () => {
  if (db) { try { db.close(); } catch (e) {} }
  app.quit();
});
