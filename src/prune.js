// Run logs and digests are per-run files with a random id in the name, so the
// data folder grows forever unless something prunes it. Keep the newest few of
// each family: they exist for "what did the last run do", not as an archive.

const fs = require('fs');
const path = require('path');

const LOG_FAMILIES = [
  /^check-run-.*\.log$/, /^check-digest-.*\.json$/, /^check-patch-.*\.json$/,
  /^ask-run-.*\.log$/, /^ask-digest-.*\.json$/, /^ask-out-.*\.json$/,
  /^execute-run-.*\.log$/, /^execute-out-.*\.json$/,
  /^brief-digest-.*\.json$/, /^brief-out-.*\.json$/, /^publish-.*\.html$/
];

const DEFAULT_KEEP = 20;

// Returns the paths it deleted, so a caller (or a test) can see what went.
function pruneRunFiles(dir, keep) {
  const limit = typeof keep === 'number' ? keep : DEFAULT_KEEP;
  const removed = [];
  let names;
  try { names = fs.readdirSync(dir); } catch (e) { return removed; }
  for (const family of LOG_FAMILIES) {
    const files = names.filter((n) => family.test(n)).map((n) => {
      const p = path.join(dir, n);
      let mtime = 0;
      try { mtime = fs.statSync(p).mtimeMs; } catch (e) { /* vanished mid-sweep */ }
      return { p, mtime };
    });
    if (files.length <= limit) continue;
    // Newest first, then drop the tail. Ties keep whichever the FS listed
    // first, which is good enough for files that differ by a run id.
    files.sort((a, b) => b.mtime - a.mtime);
    for (const f of files.slice(limit)) {
      try { fs.unlinkSync(f.p); removed.push(f.p); } catch (e) { /* in use by a running script */ }
    }
  }
  return removed;
}

module.exports = { LOG_FAMILIES, DEFAULT_KEEP, pruneRunFiles };
