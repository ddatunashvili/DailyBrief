// Three-way merge of the kanban board, for a save from the page.
//
//   base   - the board the page was last given (what the user started from)
//   mine   - the board the page sends back (the user's edits)
//   theirs - kanban.json as it is on disk right now, re-read under the lock
//            (AI runs and scripts may have patched it since base)
//
// Merged per task id, separately for `tasks` and `archive`:
//   - only in mine (new)                       -> add
//   - only in theirs (a script added it)       -> keep
//   - gone from mine, theirs unchanged         -> delete
//   - gone from mine, theirs changed it        -> keep theirs
//   - gone from theirs, mine unchanged         -> delete (a script removed it)
//   - gone from theirs, mine changed it        -> keep mine
//   - mine == base -> theirs; theirs == base   -> mine
//   - both changed -> per field: mine if mine changed that field, else theirs
// History arrays (comments, aiNotes) are never dropped: both sides' entries
// are kept, matched by their own timestamp + text. A comment acked on either
// side stays acked.
// A task moved to the archive by the user stays archived, even if a script
// touched it meanwhile.
// Top-level keys other than tasks/archive follow the same per-field rule.
//
// opts.mineFields: the fields the page actually owns (what sanitizeKanban
// keeps). Every other field is the scripts' business: mine never carries it,
// so its absence there is not a deletion - theirs (or base) wins.
// opts.normalize(task): what the page's own sanitizer would make of a base
// task. "Did mine change this?" compares mine against the normalized base,
// so a trim the sanitizer does (e.g. only the last 10 AI notes) never reads
// as a user edit.

const LISTS = ['tasks', 'archive'];
const HISTORY = {
  comments: (c) => [c && c.by, c && c.at, c && c.text].join('\u0001'),
  aiNotes: (n) => [n && n.at, n && n.text].join('\u0001')
};

// Stable JSON: key order differs between what PowerShell and Node write.
function canon(v) {
  if (Array.isArray(v)) return '[' + v.map(canon).join(',') + ']';
  if (v && typeof v === 'object') {
    return '{' + Object.keys(v).filter((k) => v[k] !== undefined).sort()
      .map((k) => JSON.stringify(k) + ':' + canon(v[k])).join(',') + '}';
  }
  return v === undefined ? 'null' : JSON.stringify(v);
}

const same = (a, b) => canon(a) === canon(b);

function owned(field, mineFields) {
  return !mineFields || mineFields.includes(field);
}

// Only the fields mine owns decide whether "mine changed this task".
function pick(task, mineFields) {
  if (!task || !mineFields) return task;
  const out = {};
  mineFields.forEach((f) => { if (task[f] !== undefined) out[f] = task[f]; });
  return out;
}

function unionHistory(field, a, b) {
  const key = HISTORY[field];
  const out = [];
  const at = new Map();
  [a, b].forEach((list) => {
    (Array.isArray(list) ? list : []).forEach((item) => {
      const k = key(item);
      if (!at.has(k)) { at.set(k, out.length); out.push(item); return; }
      // A comment acked on either side stays acked.
      const prev = out[at.get(k)];
      if (prev && item && prev.state === 'new' && item.state === 'applied') out[at.get(k)] = item;
    });
  });
  // Oldest first, as both sides write them; stable for equal timestamps.
  return out.map((x, i) => [x, i])
    .sort((p, q) => String((p[0] && p[0].at) || '').localeCompare(String((q[0] && q[0].at) || '')) || p[1] - q[1])
    .map((p) => p[0]);
}

// Field-level merge of one object (a task, or the board's top level).
function mergeFields(base, mine, theirs, mineFields, skip, baseForMine) {
  const b = base || {}, m = mine || {}, t = theirs || {};
  const bm = baseForMine || b;
  const out = {};
  const keys = new Set([...Object.keys(t), ...Object.keys(m), ...Object.keys(b)]);
  keys.forEach((k) => {
    if (skip && skip.includes(k)) return;
    let v;
    if (HISTORY[k] && owned(k, mineFields)) v = unionHistory(k, t[k], m[k]);
    else if (owned(k, mineFields) && !same(m[k], bm[k])) v = m[k];
    else v = k in t ? t[k] : (owned(k, mineFields) ? undefined : b[k]);
    if (v !== undefined) out[k] = v;
  });
  return out;
}

function byId(list) {
  const m = new Map();
  (Array.isArray(list) ? list : []).forEach((x) => { if (x && x.id) m.set(String(x.id), x); });
  return m;
}

function mergeList(baseList, mineList, theirsList, mineFields, normalize) {
  const B = byId(baseList), M = byId(mineList), T = byId(theirsList);
  // Theirs' order first (what is on disk), then the page's new tasks.
  const ids = [...T.keys(), ...[...M.keys()].filter((id) => !T.has(id))];
  const out = [];
  ids.forEach((id) => {
    const b = B.get(id), m = M.get(id), t = T.get(id);
    const bn = b && normalize ? (normalize(b) || b) : b;
    const mineChanged = !b || !m || !same(pick(m, mineFields), pick(bn, mineFields));
    const theirsChanged = !b || !t || !same(t, b);
    if (m && !t) {
      // New on the page, or a script removed it: keep only if mine touched it.
      if (!b || mineChanged) out.push(m);
      return;
    }
    if (t && !m) {
      // Added by a script, or deleted on the page: the page's delete wins
      // unless the script changed the task since the page last saw it.
      if (!b || theirsChanged) out.push(t);
      return;
    }
    if (!mineChanged) { out.push(t); return; }
    // theirs unchanged or both changed: the per-field rule covers both.
    out.push(mergeFields(b, m, t, mineFields, null, bn));
  });
  return out;
}

function mergeBoard(base, mine, theirs, opts) {
  const mineFields = opts && opts.mineFields;
  const normalize = opts && opts.normalize;
  const b = base || {}, m = mine || {}, t = theirs || {};
  const merged = mergeFields(b, m, t, null, LISTS);
  // Top-level keys the page never sends (it only sends the two lists) are
  // not deletions either.
  Object.keys(t).forEach((k) => { if (!LISTS.includes(k) && !(k in m)) merged[k] = t[k]; });
  LISTS.forEach((k) => { merged[k] = mergeList(b[k], m[k], t[k], mineFields, normalize); });
  // The user archived it: it leaves the board even if a script touched it.
  const archivedByMine = new Set((Array.isArray(m.archive) ? m.archive : []).map((x) => x && String(x.id)));
  merged.tasks = merged.tasks.filter((x) => !(archivedByMine.has(String(x.id)) &&
    merged.archive.some((a) => String(a.id) === String(x.id))));
  // ...and a task the user restored from the archive leaves the archive.
  const onBoardByMine = new Set((Array.isArray(m.tasks) ? m.tasks : []).map((x) => x && String(x.id)));
  merged.archive = merged.archive.filter((x) => !(onBoardByMine.has(String(x.id)) &&
    merged.tasks.some((a) => String(a.id) === String(x.id))));
  return merged;
}

module.exports = { mergeBoard, canon };
