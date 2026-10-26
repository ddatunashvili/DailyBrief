const test = require('node:test');
const assert = require('node:assert');
const { createLimiter } = require('../src/queue');

// A job that stays open until the test lets it go, so "how many are running"
// can be observed at every step instead of guessed from timings.
function gate() {
  let open;
  const p = new Promise((r) => { open = r; });
  return { p, open };
}

const tick = () => new Promise((r) => setImmediate(r));

test('never runs more than max jobs at once', async () => {
  const limit = createLimiter(3);
  const gates = Array.from({ length: 7 }, gate);
  let running = 0, peak = 0;
  const all = gates.map((g, i) => limit.run(async () => {
    running++; peak = Math.max(peak, running);
    await g.p;
    running--;
    return i;
  }));
  await tick();
  assert.strictEqual(limit.active, 3);
  assert.strictEqual(limit.pending, 4);
  gates.forEach((g) => g.open());
  assert.deepStrictEqual(await Promise.all(all), [0, 1, 2, 3, 4, 5, 6]);
  assert.strictEqual(peak, 3);
  assert.strictEqual(limit.active, 0);
});

test('starts waiting jobs in arrival order as slots free up', async () => {
  const limit = createLimiter(1);
  const order = [];
  const g = gate();
  const first = limit.run(async () => { order.push('a'); await g.p; });
  const rest = ['b', 'c', 'd'].map((n) => limit.run(async () => { order.push(n); }));
  await tick();
  assert.deepStrictEqual(order, ['a']);
  g.open();
  await Promise.all([first, ...rest]);
  assert.deepStrictEqual(order, ['a', 'b', 'c', 'd']);
});

test('a failing job rejects its own promise and frees the slot', async () => {
  const limit = createLimiter(1);
  const bad = limit.run(() => { throw new Error('boom'); });
  const badAsync = limit.run(async () => { throw new Error('later'); });
  const good = limit.run(async () => 'fine');
  await assert.rejects(bad, /boom/);
  await assert.rejects(badAsync, /later/);
  assert.strictEqual(await good, 'fine');
  assert.strictEqual(limit.active, 0);
});

test('clear drops jobs that have not started, running ones finish', async () => {
  const limit = createLimiter(2);
  const g = gate();
  let started = 0;
  const jobs = Array.from({ length: 5 }, () => limit.run(async () => { started++; await g.p; return 'ran'; }));
  await tick();
  assert.strictEqual(limit.clear(), 3);
  assert.strictEqual(limit.pending, 0);
  g.open();
  const results = await Promise.all(jobs);
  assert.deepStrictEqual(results, ['ran', 'ran', undefined, undefined, undefined]);
  assert.strictEqual(started, 2);
});

test('an unusable max falls back to one at a time', async () => {
  for (const bad of [0, -3, NaN, 'x', undefined]) {
    assert.strictEqual(createLimiter(bad).max, 1);
  }
  assert.strictEqual(createLimiter(2.7).max, 2);
});
