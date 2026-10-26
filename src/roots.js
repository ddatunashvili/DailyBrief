// Work roots: the folders this user works in. Mirrors core\roots.ps1
// (Get-WorkRoots) so the app shows and searches exactly what the scripts walk:
// roots.json entries first, then the Windows defaults, deduped
// case-insensitively, trailing backslashes stripped, missing folders dropped.
// No Electron in here - the caller passes the shell folders and an exists().

const fs = require('fs');
const path = require('path');

function trimSlash(p) {
  return String(p || '').trim().replace(/\\+$/, '');
}

// The defaults, in core\roots.ps1 order. desktop/documents are the shell
// folders (app.getPath), home is USERPROFILE.
function defaultRoots(opts) {
  const o = opts || {};
  const home = trimSlash(o.home);
  const list = [o.desktop, o.documents];
  if (home) {
    list.push(
      home + '\\OneDrive\\Desktop', home + '\\OneDrive\\Documents',
      home + '\\Desktop', home + '\\Documents',
      home + '\\source', home + '\\projects'
    );
    if (o.withDownloads) list.push(home + '\\Downloads');
  }
  return list.map(trimSlash).filter(Boolean);
}

function dedupe(list) {
  const seen = new Set();
  const out = [];
  list.forEach((p) => {
    const t = trimSlash(p);
    const k = t.toLowerCase();
    if (!t || seen.has(k)) return;
    seen.add(k);
    out.push(t);
  });
  return out;
}

// roots.json text -> its entries (as written; may include folders that are gone).
function parseRootsJson(text) {
  try {
    const j = JSON.parse(String(text || '').replace(/^\uFEFF/, ''));
    const r = j && Array.isArray(j.roots) ? j.roots : [];
    return dedupe(r.filter((x) => typeof x === 'string'));
  } catch (e) {
    return [];
  }
}

// A drive root (G:\) is refused: PowerShell reads "G:" as "the current
// folder on G:", and walking a whole drive every 30 minutes is not a work
// folder anyway. Relative paths are refused for the same ambiguity.
function isAcceptableRoot(p) {
  const t = trimSlash(p);
  if (!/^[A-Za-z]:\\[^\\]/.test(t) && !/^\\\\[^\\]+\\[^\\]+/.test(t)) return false;
  return !/[<>"|?*]/.test(t.slice(2));
}

// What Settings saves: acceptable, existing directories, deduped.
function cleanUserRoots(list, isDir) {
  const check = isDir || defaultIsDir;
  return dedupe((Array.isArray(list) ? list : []).filter((x) => typeof x === 'string'))
    .filter((p) => isAcceptableRoot(p) && check(p))
    .slice(0, 100);
}

function serializeRoots(list) {
  return JSON.stringify({ roots: list }, null, 2);
}

// The effective list the scripts walk, user entries first.
function effectiveRoots(userRoots, defaults, isDir) {
  const check = isDir || defaultIsDir;
  return dedupe([].concat(userRoots || [], defaults || [])).filter((p) => check(p));
}

// For the Settings page: every roots.json entry (flagged when gone, so it can
// still be removed) plus the defaults that exist and are not already listed.
function describeRoots(userRoots, defaults, isDir) {
  const check = isDir || defaultIsDir;
  const user = dedupe(userRoots || []);
  const keys = new Set(user.map((p) => p.toLowerCase()));
  return {
    user: user.map((dir) => ({ dir, missing: !check(dir) })),
    builtin: dedupe(defaults || []).filter((p) => !keys.has(p.toLowerCase()) && check(p))
  };
}

function defaultIsDir(p) {
  try { return fs.statSync(p).isDirectory(); } catch (e) { return false; }
}

// Atomic write: temp file in the same folder, then rename over the target.
// UTF-8 without BOM - JSON.stringify output written as 'utf8' has none.
function writeRootsFile(file, list) {
  const tmp = path.join(path.dirname(file), '.' + path.basename(file) + '.' + process.pid + '.tmp');
  fs.writeFileSync(tmp, serializeRoots(list), 'utf8');
  try {
    fs.renameSync(tmp, file);
  } catch (e) {
    try { fs.unlinkSync(tmp); } catch (e2) { /* nothing left to clean */ }
    throw e;
  }
}

function readRootsFile(file) {
  try { return parseRootsJson(fs.readFileSync(file, 'utf8')); } catch (e) { return []; }
}

module.exports = {
  trimSlash, defaultRoots, dedupe, parseRootsJson, isAcceptableRoot, cleanUserRoots,
  serializeRoots, effectiveRoots, describeRoots, writeRootsFile, readRootsFile
};
