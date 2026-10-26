const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { withBoardLock, lockPath } = require('../src/boardlock');

function tmpDir() {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'dailybrief-lock-'));
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

test('concurrent callers never hold the lock at the same time', async () => {
  const dir = tmpDir();
  const counter = path.join(dir, 'n.txt');
  fs.writeFileSync(counter, '0');
  let inside = 0, peak = 0;
  // Read-modify-write with a pause in the middle: unlocked, increments get lost.
  await Promise.all(Array.from({ length: 8 }, () => withBoardLock(dir, async () => {
    inside++; peak = Math.max(peak, inside);
    const n = Number(fs.readFileSync(counter, 'utf8'));
    await sleep(5);
    fs.writeFileSync(counter, String(n + 1));
    inside--;
  }, { retryMs: 5 })));
  assert.strictEqual(peak, 1);
  assert.strictEqual(fs.readFileSync(counter, 'utf8'), '8');
  assert.ok(!fs.existsSync(lockPath(dir)), 'released at the end');
});

test('the lock file carries "<pid> <iso time>" while held', async () => {
  const dir = tmpDir();
  await withBoardLock(dir, () => {
    const [pid, at] = fs.readFileSync(lockPath(dir), 'utf8').split(' ');
    assert.strictEqual(pid, String(process.pid));
    assert.ok(!isNaN(Date.parse(at)));
  });
});

test('a stale lock left by a crashed holder is stolen', async () => {
  const dir = tmpDir();
  const file = lockPath(dir);
  fs.writeFileSync(file, '99999 2020-01-01T00:00:00.000Z');
  const old = new Date(Date.now() - 10 * 60 * 1000);
  fs.utimesSync(file, old, old);
  const r = await withBoardLock(dir, () => 'got it', { timeoutMs: 1000 });
  assert.strictEqual(r, 'got it');
  assert.ok(!fs.existsSync(file));
});

test('a fresh lock held elsewhere times out instead of writing unlocked', async () => {
  const dir = tmpDir();
  fs.writeFileSync(lockPath(dir), '99999 now');
  let ran = false;
  await assert.rejects(
    withBoardLock(dir, () => { ran = true; }, { timeoutMs: 200, retryMs: 20 }),
    (e) => e.code === 'EBOARDLOCK'
  );
  assert.strictEqual(ran, false);
  assert.ok(fs.existsSync(lockPath(dir)), 'someone else\'s lock is left alone');
});

test('the lock is released when the body throws', async () => {
  const dir = tmpDir();
  await assert.rejects(withBoardLock(dir, () => { throw new Error('boom'); }), /boom/);
  assert.ok(!fs.existsSync(lockPath(dir)));
  assert.strictEqual(await withBoardLock(dir, () => 2, { timeoutMs: 200 }), 2);
});
