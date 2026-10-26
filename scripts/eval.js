#!/usr/bin/env node
// Eval harness: runs the real pipeline against a COPY of this user's data and
// judges the output, so a prompt or digest change can be measured instead of
// eyeballed. The real data folder is only ever read (to copy it); every
// script runs with DAILYBRIEF_DATA pointing at the copy in the temp dir.
//
//   npm run eval                       daily brief + kanban check
//   npm run eval -- --mode brief       daily brief only
//   npm run eval -- --mode check       kanban check only
//   npm run eval -- --keep             keep the temp copy to inspect it
//   npm run eval -- --data <dir>       copy this data folder instead
//   npm run eval -- --report <file>    also write the results as JSON
//                                      (eval-out/ is gitignored)
//
// It spends real tokens (Sonnet for the brief, Haiku for the check). The
// fixtures hold personal data, so they live in the temp dir and are deleted
// afterwards unless --keep is given.

const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawn } = require('child_process');
const C = require('../src/eval-checks');

const ROOT = path.resolve(__dirname, '..');
const CORE = path.join(ROOT, 'core');
const RUN_TIMEOUT_MS = 20 * 60 * 1000;

function parseArgs(argv) {
  const a = { mode: 'all', keep: false, data: '', report: '' };
  for (let i = 0; i < argv.length; i++) {
    const k = argv[i];
    if (k === '--keep') a.keep = true;
    else if (k === '--mode') a.mode = argv[++i] || '';
    else if (k.startsWith('--mode=')) a.mode = k.slice(7);
    else if (k === '--data') a.data = argv[++i] || '';
    else if (k === '--report') a.report = argv[++i] || '';
    else if (k === '-h' || k === '--help') a.help = true;
    else throw new Error('unknown argument: ' + k);
  }
  if (!['brief', 'check', 'all'].includes(a.mode)) throw new Error('--mode must be brief, check or all');
  return a;
}

// Same rule the app uses: DAILYBRIEF_DATA, else core/ in a checkout. A
// checkout with no data in it falls back to the packaged app's folder.
function resolveDataDir(explicit) {
  if (explicit) return path.resolve(explicit);
  if (process.env.DAILYBRIEF_DATA) return path.resolve(process.env.DAILYBRIEF_DATA);
  if (fs.existsSync(path.join(CORE, 'kanban.json'))) return CORE;
  const packaged = path.join(process.env.APPDATA || '', 'DailyBrief', 'data');
  if (process.env.APPDATA && fs.existsSync(path.join(packaged, 'kanban.json'))) return packaged;
  return CORE;
}

// Local date, the way PowerShell's Get-Date -Format yyyy-MM-dd sees it.
function localToday() {
  const d = new Date();
  const p = (n) => String(n).padStart(2, '0');
  return d.getFullYear() + '-' + p(d.getMonth() + 1) + '-' + p(d.getDate());
}

// Scripts and prompts are install content, not data: in a checkout they sit
// in core/ next to the data, and the copy must not be mistaken for them. Old
// run logs and digests are dropped so every log in the copy is this run's.
const SKIP_RE = /(\.ps1|^prompt.*\.md|^strings.*\.json|\.log|^check-(digest|patch|run)-.*|^ask-(digest|out|run)-.*|^brief-(digest|out)-.*|^execute-.*|^publish.*|^dailybrief\.db.*)$/i;

function buildFixture(dataDir) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dailybrief-eval-'));
  const real = path.resolve(dataDir).toLowerCase();
  if (path.resolve(dir).toLowerCase().startsWith(real + path.sep) || path.resolve(dir).toLowerCase() === real) {
    throw new Error('fixture would land inside the real data folder');
  }
  fs.cpSync(dataDir, dir, {
    recursive: true,
    filter: (src) => {
      if (path.resolve(src) === path.resolve(dataDir)) return true;
      // Only top-level files are filtered; sub-folders (briefs/, snapshots/...) copy whole.
      if (path.dirname(path.resolve(src)) !== path.resolve(dataDir)) return true;
      try { if (fs.statSync(src).isDirectory()) return true; } catch (e) { return false; }
      return !SKIP_RE.test(path.basename(src));
    }
  });
  return dir;
}

function readJsonSafe(p) {
  try { return JSON.parse(fs.readFileSync(p, 'utf8').replace(/^﻿/, '')); } catch (e) { return null; }
}

function readText(p) {
  try { return fs.readFileSync(p, 'utf8'); } catch (e) { return ''; }
}

function boardIds(dir) {
  const k = readJsonSafe(path.join(dir, 'kanban.json')) || {};
  return [].concat(Array.isArray(k.tasks) ? k.tasks : [], Array.isArray(k.archive) ? k.archive : [])
    .map((t) => String(t && t.id || '')).filter(Boolean);
}

function runPs(script, args, dataDir) {
  return new Promise((resolve) => {
    const started = Date.now();
    const env = Object.assign({}, process.env, { DAILYBRIEF_DATA: dataDir });
    const ps = spawn('powershell.exe', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
      '-File', path.join(CORE, script)].concat(args), { env, cwd: dataDir, windowsHide: true });
    let out = '';
    ps.stdout.on('data', (b) => { out += b; });
    ps.stderr.on('data', (b) => { out += b; });
    const timer = setTimeout(() => { out += '\n[eval] timeout, killed'; ps.kill(); }, RUN_TIMEOUT_MS);
    ps.on('error', (e) => { clearTimeout(timer); resolve({ code: -1, out: String(e), ms: Date.now() - started }); });
    ps.on('exit', (code) => { clearTimeout(timer); resolve({ code, out, ms: Date.now() - started }); });
  });
}

// Fingerprint of the real data folder's files a run would write, to prove
// afterwards that nothing touched them.
function realFingerprint(dataDir, today) {
  const files = ['kanban.json', 'questions.json', 'STATE.md', 'GOALS.md', 'last-run.log',
    path.join('briefs', today + '.json'), path.join('briefings', today + '.md')];
  return files.map((f) => {
    try { const s = fs.statSync(path.join(dataDir, f)); return f + ':' + s.size + ':' + s.mtimeMs; } catch (e) { return f + ':-'; }
  }).join('|');
}

async function evalBrief(fx, today, preIds) {
  // The brief skips itself when today's already exists - remove it from the copy.
  for (const f of [path.join('briefs', today + '.json'), path.join('briefings', today + '.md'), 'last-run.log']) {
    try { fs.rmSync(path.join(fx, f), { force: true }); } catch (e) { /* not there */ }
  }
  const run = await runPs('daily-brief.ps1', ['-NoShow'], fx);
  const log = readText(path.join(fx, 'last-run.log'));
  const usage = C.parseUsage(log);
  const failures = [];
  const notes = [];
  const brief = readJsonSafe(path.join(fx, 'briefs', today + '.json'));
  if (!brief) failures.push('briefs/' + today + '.json missing or not valid JSON');
  else {
    C.validateBrief(brief).forEach((i) => failures.push(i));
    C.forbiddenTitles((brief.tasks || []).map((t) => t && t.title))
      .forEach((t) => failures.push('forbidden task title: "' + t + '"'));
    C.trendOnlyWarnings(brief.warnings).forEach((w) => failures.push('trend-only warning: "' + (w.label || w.text) + '"'));
    const prose = C.proseStats(C.briefText(brief));
    prose.flags.forEach((f) => failures.push('prose: ' + f));
    notes.push('prose: ' + prose.words + ' words, ' + prose.avgWordsPerSentence + ' words/sentence, article ratio ' + prose.articleRatio);
  }
  const out = readJsonSafe(path.join(fx, 'brief-out-' + today + '.json'));
  if (out && out.kanban) {
    const refs = (out.kanban.updates || []).map((u) => u && u.id);
    C.missingIds(refs, preIds).forEach((id) => failures.push('kanban.updates references unknown id: ' + id));
    C.forbiddenTitles((out.kanban.newTasks || []).map((t) => t && t.title))
      .forEach((t) => failures.push('forbidden new task: "' + t + '"'));
  }
  C.missingIds(preIds, boardIds(fx)).forEach((id) => failures.push('task id lost from the board: ' + id));
  const digest = path.join(fx, 'brief-digest-' + today + '.json');
  if (fs.existsSync(digest)) notes.push('digest: ' + fs.statSync(digest).size + ' bytes');
  usage.warnings.forEach((w) => notes.push(w));
  if (run.code !== 0) failures.push('daily-brief.ps1 exited ' + run.code);
  return { mode: 'brief', run, usage, failures, notes };
}

async function evalCheck(fx, preIds) {
  const runId = 'eval' + Date.now().toString(36);
  const run = await runPs('kanban-check.ps1', ['-RunId', runId], fx);
  const log = readText(path.join(fx, 'check-run-' + runId + '.log'));
  const usage = C.parseUsage(log);
  const failures = [];
  const notes = [];
  // The script deletes its patch once applied; a leftover one is judged too.
  const patch = readJsonSafe(path.join(fx, 'check-patch-' + runId + '.json'));
  if (patch) {
    C.missingIds((patch.updates || []).map((u) => u && u.id), preIds)
      .forEach((id) => failures.push('patch references unknown id: ' + id));
    C.forbiddenTitles((patch.newTasks || []).map((t) => t && t.title))
      .forEach((t) => failures.push('forbidden new task: "' + t + '"'));
  }
  C.missingIds(preIds, boardIds(fx)).forEach((id) => failures.push('task id lost from the board: ' + id));
  if (usage.skipped) notes.push(log.split(/\r?\n/)[0]);
  usage.warnings.forEach((w) => notes.push(w));
  if (run.code !== 0) failures.push('kanban-check.ps1 exited ' + run.code);
  return { mode: 'check', run, usage, failures, notes };
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    console.log(fs.readFileSync(__filename, 'utf8').split('\n').slice(1, 18).join('\n'));
    return 0;
  }
  if (process.platform !== 'win32') throw new Error('the pipeline is PowerShell 5.1 - run this on Windows');
  const dataDir = resolveDataDir(args.data);
  if (!fs.existsSync(path.join(dataDir, 'kanban.json'))) throw new Error('no kanban.json in ' + dataDir);
  const today = localToday();
  const before = realFingerprint(dataDir, today);
  const fx = buildFixture(dataDir);
  console.log('data:    ' + dataDir + '  (read-only)');
  console.log('fixture: ' + fx);
  const preIds = boardIds(fx);
  const results = [];
  try {
    if (args.mode === 'brief' || args.mode === 'all') {
      console.log('running daily brief...');
      results.push(await evalBrief(fx, today, preIds));
    }
    if (args.mode === 'check' || args.mode === 'all') {
      console.log('running kanban check...');
      results.push(await evalCheck(fx, boardIds(fx)));
    }
  } finally {
    if (!args.keep) fs.rmSync(fx, { recursive: true, force: true });
  }
  const untouched = realFingerprint(dataDir, today) === before;

  console.log('');
  console.log(C.formatTable(
    ['mode', 'exit', 'wall s', 'script s', 'model s', 'turns', 'in tok', 'out tok', 'cost $', 'result'],
    results.map((r) => [
      r.mode, r.run.code, (r.run.ms / 1000).toFixed(1), r.usage.scriptSeconds || '',
      r.usage.durationMs ? (r.usage.durationMs / 1000).toFixed(1) : '', r.usage.turns || '',
      r.usage.inputTokens, r.usage.outputTokens, r.usage.costUsd.toFixed(4),
      r.usage.skipped ? 'skipped' : (r.failures.length ? 'FAIL (' + r.failures.length + ')' : 'pass')
    ])));
  for (const r of results) {
    if (!r.failures.length && !r.notes.length) continue;
    console.log('\n[' + r.mode + ']');
    r.failures.forEach((f) => console.log('  FAIL ' + f));
    r.notes.forEach((n) => console.log('  note ' + n));
  }
  if (!untouched) console.log('\nWARNING: files in the real data folder changed during the eval (is the app running?)');
  if (args.keep) console.log('\nkept: ' + fx);
  if (args.report) {
    fs.mkdirSync(path.dirname(path.resolve(args.report)), { recursive: true });
    fs.writeFileSync(args.report, JSON.stringify({ today, results: results.map((r) => ({
      mode: r.mode, exit: r.run.code, wallMs: r.run.ms, usage: r.usage, failures: r.failures, notes: r.notes
    })) }, null, 2));
  }
  return results.some((r) => r.failures.length) ? 1 : 0;
}

if (require.main === module) {
  main().then((code) => { process.exitCode = code; }, (e) => {
    console.error('eval: ' + e.message);
    process.exitCode = 2;
  });
}

module.exports = { parseArgs, resolveDataDir, SKIP_RE };
