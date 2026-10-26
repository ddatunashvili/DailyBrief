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

// roots.json text -> { roots, disabled }. `disabled` holds built-in folders
// the user switched off in Settings; the defaults are otherwise always walked.
function parseRootsConfig(text) {
  try {
    const j = JSON.parse(String(text || '').replace(/^\uFEFF/, ''));
    const pick = (k) => (j && Array.isArray(j[k]) ? dedupe(j[k].filter((x) => typeof x === 'string')) : []);
    return { roots: pick('roots'), disabled: pick('disabled') };
  } catch (e) {
    return { roots: [], disabled: [] };
  }
}

// roots.json text -> its entries (as written; may include folders that are gone).
function parseRootsJson(text) {
  return parseRootsConfig(text).roots;
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

function serializeRoots(list, disabled) {
  const o = { roots: list };
  if (disabled && disabled.length) o.disabled = disabled;
  return JSON.stringify(o, null, 2);
}

// Only real defaults can be switched off, and a folder the user lists again
// is no longer off: the explicit entry wins.
function cleanDisabled(disabled, defaults, userRoots) {
  const def = new Set(dedupe(defaults || []).map((p) => p.toLowerCase()));
  const user = new Set(dedupe(userRoots || []).map((p) => p.toLowerCase()));
  return dedupe((Array.isArray(disabled) ? disabled : []).filter((x) => typeof x === 'string'))
    .filter((p) => def.has(p.toLowerCase()) && !user.has(p.toLowerCase()));
}

// The effective list the scripts walk, user entries first, switched-off
// defaults left out.
function effectiveRoots(userRoots, defaults, isDir, disabled) {
  const check = isDir || defaultIsDir;
  const off = new Set(dedupe(disabled || []).map((p) => p.toLowerCase()));
  const def = dedupe(defaults || []).filter((p) => !off.has(p.toLowerCase()));
  return dedupe([].concat(userRoots || [], def)).filter((p) => check(p));
}

// For the Settings page: every roots.json entry (flagged when gone, so it can
// still be removed) plus the defaults that exist and are not already listed,
// switched-off ones included (flagged) so they can be turned back on.
function describeRoots(userRoots, defaults, isDir, disabled) {
  const check = isDir || defaultIsDir;
  const user = dedupe(userRoots || []);
  const keys = new Set(user.map((p) => p.toLowerCase()));
  const off = new Set(dedupe(disabled || []).map((p) => p.toLowerCase()));
  return {
    user: user.map((dir) => ({ dir, missing: !check(dir) })),
    builtin: dedupe(defaults || []).filter((p) => !keys.has(p.toLowerCase()) && check(p))
      .map((dir) => ({ dir, disabled: off.has(dir.toLowerCase()) }))
  };
}

function defaultIsDir(p) {
  try { return fs.statSync(p).isDirectory(); } catch (e) { return false; }
}

// Atomic write: temp file in the same folder, then rename over the target.
// UTF-8 without BOM - JSON.stringify output written as 'utf8' has none.
function writeRootsFile(file, list, disabled) {
  const tmp = path.join(path.dirname(file), '.' + path.basename(file) + '.' + process.pid + '.tmp');
  fs.writeFileSync(tmp, serializeRoots(list, disabled), 'utf8');
  try {
    fs.renameSync(tmp, file);
  } catch (e) {
    try { fs.unlinkSync(tmp); } catch (e2) { /* nothing left to clean */ }
    throw e;
  }
}

function readRootsFile(file) {
  return readRootsConfig(file).roots;
}

function readRootsConfig(file) {
  try { return parseRootsConfig(fs.readFileSync(file, 'utf8')); } catch (e) { return { roots: [], disabled: [] }; }
}

module.exports = {
  trimSlash, defaultRoots, dedupe, parseRootsJson, parseRootsConfig, isAcceptableRoot, cleanUserRoots,
  cleanDisabled, serializeRoots, effectiveRoots, describeRoots, writeRootsFile, readRootsFile, readRootsConfig
};
