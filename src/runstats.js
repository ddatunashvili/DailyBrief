// Per-mode averages over the run journal (ai-runs.jsonl), so the AI page can
// show what a typical check or brief costs now - and whether a change to the
// pipeline actually made it faster or cheaper.
//
// Only runs that reached the model count: a skipped check (zero activity, zero
// tokens), a run the user stopped, one that timed out or never started would
// drag the average toward numbers no real run has.

const COUNTED = new Set(['ok', 'partial', 'thin', 'incomplete']);

// runs: journal entries oldest first. -> [{ mode, count, inputTokens,
// outputTokens, costUsd, durationSec }], the most recently used mode first.
function averageByMode(runs, lastN) {
  const n = lastN > 0 ? lastN : 10;
  const byMode = new Map();
  const list = Array.isArray(runs) ? runs : [];
  for (let i = list.length - 1; i >= 0; i--) {
    const r = list[i];
    if (!r || !r.mode || !COUNTED.has(r.status)) continue;
    if ((r.inputTokens || 0) + (r.outputTokens || 0) <= 0) continue;
    if (!byMode.has(r.mode)) byMode.set(r.mode, []);
    const bucket = byMode.get(r.mode);
    if (bucket.length < n) bucket.push(r);
  }
  return Array.from(byMode, ([mode, rs]) => {
    const avg = (k) => rs.reduce((s, r) => s + (Number(r[k]) || 0), 0) / rs.length;
    return {
      mode,
      count: rs.length,
      inputTokens: Math.round(avg('inputTokens')),
      outputTokens: Math.round(avg('outputTokens')),
      costUsd: avg('costUsd'),
      durationSec: Math.round(avg('durationSec'))
    };
  });
}

module.exports = { averageByMode };
