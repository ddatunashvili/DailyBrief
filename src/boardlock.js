// The board lock, Node side. Mirrors core\lock.ps1 exactly, so main.js and
// every PowerShell script serialize their read-modify-writes of the shared
// board files (kanban.json, questions.json, ideas.json):
//   - <data>\board.lock created exclusively ('wx')  = lock held
//   - content "<pid> <iso time>", for diagnostics only
//   - a lock file older than 120 s (by mtime) is stale - its holder crashed -
//     and may be removed
//   - release = delete the file
// Waiting never blocks the main process: attempts are spaced with timers.
//
// The body must re-read whatever it modifies INSIDE the lock: a value read
// before acquiring it and written inside is still a lost update.

const fs = require('fs');
const path = require('path');

const LOCK_NAME = 'board.lock';
const STALE_MS = 120 * 1000;
const RETRY_MS = 75;
const DEFAULT_TIMEOUT_MS = 10000;

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function lockPath(dataDir) { return path.join(dataDir, LOCK_NAME); }

// One attempt: true when this call now holds the lock.
function tryAcquire(file, staleMs) {
  try {
    fs.writeFileSync(file, process.pid + ' ' + new Date().toISOString(), { flag: 'wx' });
    return true;
  } catch (e) {
    if (e.code !== 'EEXIST') throw e;
  }
  // Held by someone: steal it only when the holder is clearly gone.
  try {
    const age = Date.now() - fs.statSync(file).mtimeMs;
    if (age > staleMs) {
      try { fs.unlinkSync(file); } catch (e) { /* someone else stole it first */ }
    }
  } catch (e) { /* vanished between attempts: the next try may win */ }
  return false;
}

async function withBoardLock(dataDir, fn, opts) {
  const o = opts || {};
  const timeoutMs = o.timeoutMs > 0 ? o.timeoutMs : DEFAULT_TIMEOUT_MS;
  const staleMs = o.staleMs > 0 ? o.staleMs : STALE_MS;
  const retryMs = o.retryMs > 0 ? o.retryMs : RETRY_MS;
  const file = lockPath(dataDir);
  const deadline = Date.now() + timeoutMs;
  while (!tryAcquire(file, staleMs)) {
    if (Date.now() > deadline) {
      const err = new Error('board lock not acquired within ' + Math.round(timeoutMs / 1000) + 's (' + file + ')');
      err.code = 'EBOARDLOCK';
      throw err;
    }
    await sleep(retryMs);
  }
  try {
    return await fn();
  } finally {
    try { fs.unlinkSync(file); } catch (e) { /* already gone */ }
  }
}

module.exports = { LOCK_NAME, STALE_MS, lockPath, withBoardLock };
