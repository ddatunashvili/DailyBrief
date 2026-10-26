const test = require('node:test');
const assert = require('node:assert');
const { averageByMode } = require('../src/runstats');

const run = (mode, inTok, outTok, sec, extra) =>
  Object.assign({ mode, status: 'ok', inputTokens: inTok, outputTokens: outTok, costUsd: 0.01, durationSec: sec }, extra || {});

test('averages tokens and seconds per mode', () => {
  const out = averageByMode([run('check', 1000, 100, 20), run('check', 3000, 300, 40), run('full', 20000, 4000, 60)]);
  const check = out.find((a) => a.mode === 'check');
  assert.deepStrictEqual(
    [check.count, check.inputTokens, check.outputTokens, check.durationSec],
    [2, 2000, 200, 30]
  );
  assert.strictEqual(out[0].mode, 'full', 'most recent mode first');
});

test('only the last N runs of a mode count', () => {
  const runs = [run('ask', 100000, 1, 999)];
  for (let i = 0; i < 10; i++) runs.push(run('ask', 1000, 100, 10));
  const ask = averageByMode(runs, 10)[0];
  assert.strictEqual(ask.count, 10);
  assert.strictEqual(ask.inputTokens, 1000);
  assert.strictEqual(ask.durationSec, 10);
});

test('skipped, stopped, failed and token-less runs are ignored', () => {
  const out = averageByMode([
    run('check', 0, 0, 2, { status: 'skipped' }),
    run('check', 5000, 500, 900, { status: 'timeout' }),
    run('check', 5000, 500, 30, { status: 'killed' }),
    run('check', 0, 0, 5),
    run('check', 2000, 200, 25)
  ]);
  assert.strictEqual(out.length, 1);
  assert.strictEqual(out[0].count, 1);
  assert.strictEqual(out[0].durationSec, 25);
});

test('an empty journal gives no averages', () => {
  assert.deepStrictEqual(averageByMode([]), []);
  assert.deepStrictEqual(averageByMode(null), []);
});
