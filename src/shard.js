// Splits the board's open tasks into one group per project, so a whole-board
// check can run as several small per-project checks instead of one big one.
//
// A task belongs to the project whose folder it watches first - the same rule
// the grouped board uses (brief-app.html taskProject). The key is the full
// folder path, not just its last segment, so two unrelated repos that happen
// to share a folder name never end up in one run. Tasks without a folder form
// one last group of their own: they still need a check, they just have no
// project to be scoped to.

const NO_PROJECT = 'No project';
// kanban:checkTasks takes at most 40 ids per run; a bigger project is split.
const MAX_IDS_PER_SHARD = 40;

function dirKey(d) {
  return String(d || '').trim().replace(/[\\/]+$/, '').toLowerCase();
}

function dirBase(d) {
  const s = String(d || '').trim().replace(/[\\/]+$/, '');
  const i = Math.max(s.lastIndexOf('\\'), s.lastIndexOf('/'));
  return i >= 0 ? s.slice(i + 1) : s;
}

// -> [{ key, name, ids }], biggest project first, folderless tasks last.
function shardByProject(tasks, maxIds) {
  const cap = maxIds > 0 ? maxIds : MAX_IDS_PER_SHARD;
  const groups = new Map();
  (Array.isArray(tasks) ? tasks : []).forEach((t) => {
    if (!t || !t.id || t.done) return;
    const first = Array.isArray(t.dirs) ? t.dirs.find((d) => dirKey(d)) : '';
    const key = first ? dirKey(first) : '';
    if (!groups.has(key)) groups.set(key, { key, name: first ? (dirBase(first) || NO_PROJECT) : NO_PROJECT, ids: [] });
    groups.get(key).ids.push(String(t.id));
  });
  const ordered = Array.from(groups.values()).sort((a, b) => {
    if ((a.key === '') !== (b.key === '')) return a.key === '' ? 1 : -1;
    return (b.ids.length - a.ids.length) || a.name.localeCompare(b.name);
  });
  const out = [];
  ordered.forEach((g) => {
    for (let i = 0; i < g.ids.length; i += cap) {
      out.push({ key: g.key, name: g.name, ids: g.ids.slice(i, i + cap) });
    }
  });
  return out;
}

module.exports = { NO_PROJECT, MAX_IDS_PER_SHARD, shardByProject };
