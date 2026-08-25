// The app's own store: one SQLite file in the user's data folder, one kv
// table, JSON values. Every read repairs mojibake and writes the repair back,
// so bad text heals once instead of on every render.
//
// Opening can fail (a native module built for another ABI, a locked file). It
// fails quietly on purpose: every caller has a file-based fallback, and an app
// that still shows yesterday's brief beats one that will not start.

const { deepFixMojibake } = require('./text');

let db = null;

function initKv(dbFile) {
  try {
    const Database = require('better-sqlite3');
    db = new Database(dbFile);
    db.pragma('journal_mode = WAL');
    db.exec('CREATE TABLE IF NOT EXISTS kv (key TEXT PRIMARY KEY, value TEXT NOT NULL)');
    return true;
  } catch (e) {
    db = null;
    return false;
  }
}

function kvReady() { return !!db; }

function kvGet(key) {
  if (!db) return null;
  try {
    const row = db.prepare('SELECT value FROM kv WHERE key = ?').get(key);
    if (!row) return null;
    const obj = JSON.parse(row.value);
    const fixed = deepFixMojibake(obj);
    if (fixed !== obj) kvSet(key, fixed);
    return fixed;
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

function kvClose() {
  if (!db) return;
  try { db.close(); } catch (e) { /* closing on the way out */ }
  db = null;
}

module.exports = { initKv, kvReady, kvClose, kvGet, kvSet, kvKeys };
