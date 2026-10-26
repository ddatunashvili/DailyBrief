const test = require('node:test');
const assert = require('node:assert');
const E = require('../src/estimate');

const NEW = '2026-10-27T10:00:00Z';
const OLD = '2026-08-25T10:00:00Z';
const run = (o) => Object.assign({ mode: 'check', status: 'ok', start: NEW, inputTokens: 4000, outputTokens: 1000, costUsd: 0.01, durationSec: 8 }, o);

test('runKind tells task, shard, new-task pass and whole board apart', () => {
  assert.strictEqual(E.runKind({ taskId: 'a' }), 'task');
  assert.strictEqual(E.runKind({ scope: 'RENODE PANEL', batchId: 'b' }), 'shard');
  assert.strictEqual(E.runKind({ scope: 'new tasks', batchId: 'b', variant: 'newtasks' }), 'newtasks');
  assert.strictEqual(E.runKind({}), 'board');
});

test('pre-lean runs are ignored, so old 100k-token runs stop inflating it', () => {
  const runs = [run({ start: OLD, inputTokens: 140000, durationSec: 67 }), run({ durationSec: 9 }), run({ durationSec: 7 })];
  const e = E.estimateFromRuns(runs, 'check', {});
  assert.strictEqual(e.durationSec, 8);
  assert.strictEqual(e.inputTokens, 4000);
  assert.strictEqual(E.estimateFromRuns([run({ start: OLD })], 'check', {}), null);
});

test('median: one slow outlier does not move the estimate', () => {
  const runs = [6, 7, 8, 9, 120].map((d) => run({ durationSec: d }));
  assert.strictEqual(E.estimateFromRuns(runs, 'check', {}).durationSec, 8);
});

test('same kind preferred when there are enough, else every run of the mode', () => {
  const runs = [
    run({ scope: 'P', batchId: 'b', durationSec: 6 }), run({ scope: 'Q', batchId: 'b', durationSec: 8 }),
    run({ durationSec: 30 }), run({ durationSec: 32 })
  ];
  assert.strictEqual(E.estimateFromRuns(runs, 'check', { scope: 'P', batchId: 'c' }).durationSec, 7);
  assert.strictEqual(E.estimateFromRuns(runs, 'check', {}).durationSec, 31);
  // One task-run only: not enough of its kind, so the whole mode answers.
  const one = runs.concat([run({ taskId: 't', durationSec: 50 })]);
  assert.strictEqual(E.estimateFromRuns(one, 'check', { taskId: 't' }).durationSec, 30);
});

test('skipped, failed and token-less runs never count', () => {
  const runs = [run({ status: 'skipped', durationSec: 1 }), run({ status: 'failed', durationSec: 300 }),
    run({ inputTokens: 0, outputTokens: 0, costUsd: 0, durationSec: 1 }), run({ durationSec: 10 })];
  assert.strictEqual(E.estimateFromRuns(runs, 'check', {}).durationSec, 10);
});
