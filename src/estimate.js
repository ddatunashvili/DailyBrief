// Run estimates from the journal (ai-runs.jsonl). Pure: main.js passes the
// parsed runs in.
//
// Why not "average of the last 10 ok runs of this mode": the journal still
// holds runs from before the lean runner (1.8.0) at 5-10x today's tokens and
// time, one slow outlier dragged a mean far up, and a 6 s per-project check
// was averaged with a 30 s whole-board one. So: lean-era runs only, the
// median, and the same kind of run when there are enough of them.

// The lean runner shipped this day; anything older is a different program.
const LEAN_SINCE = Date.parse('2026-10-26T15:00:00Z');
const WINDOW = 9;        // newest runs considered
const MIN_SAME_KIND = 2; // below this, fall back to every run of the mode

// What a run is, beyond its mode: one task, one project's shard of a batch,
// the batch's new-task pass, or the whole board.
function runKind(r) {
  const x = r || {};
  if (x.variant === 'newtasks') return 'newtasks';
  if (x.taskId) return 'task';
  if (x.scope || x.batchId) return 'shard';
  return 'board';
}

function median(nums) {
  const a = nums.filter((n) => typeof n === 'number' && isFinite(n)).sort((p, q) => p - q);
  if (!a.length) return 0;
  const m = Math.floor(a.length / 2);
  return a.length % 2 ? a[m] : (a[m - 1] + a[m]) / 2;
}

function usable(r, mode, since) {
  if (!r || r.mode !== mode || r.status !== 'ok') return false;
  if (!((r.inputTokens || 0) + (r.outputTokens || 0) > 0 || (r.costUsd || 0) > 0)) return false;
  const t = Date.parse(r.start || '');
  return !(since && (!isFinite(t) || t < since));
}

// -> estimate from history, or null when there is none worth trusting.
function estimateFromRuns(runs, mode, ctx, opts) {
  const o = opts || {};
  const since = o.since === undefined ? LEAN_SINCE : o.since;
  const all = (Array.isArray(runs) ? runs : []).filter((r) => usable(r, mode, since));
  if (!all.length) return null;
  const kind = runKind(ctx);
  const same = all.filter((r) => runKind(r) === kind);
  const pool = (same.length >= MIN_SAME_KIND ? same : all).slice(-WINDOW);
  const med = (k) => median(pool.map((r) => r[k] || 0));
  return {
    inputTokens: Math.round(med('inputTokens')),
    outputTokens: Math.round(med('outputTokens')),
    costUsd: med('costUsd'),
    durationSec: Math.max(1, Math.round(med('durationSec'))),
    source: 'history',
    samples: pool.length
  };
}

module.exports = { LEAN_SINCE, runKind, median, estimateFromRuns };
