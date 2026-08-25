const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { pruneRunFiles } = require('../src/prune');

function tmpDir() {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'dailybrief-prune-'));
}

// mtime, not name, decides what survives - so the fixture stamps them.
function write(dir, name, minutesAgo) {
  const p = path.join(dir, name);
  fs.writeFileSync(p, 'x');
  const t = new Date(Date.now() - minutesAgo * 60000);
  fs.utimesSync(p, t, t);
  return p;
}

test('keeps the newest N of a family and deletes the rest', () => {
  const dir = tmpDir();
  for (let i = 0; i < 10; i++) write(dir, `check-run-${i}.log`, i);
  pruneRunFiles(dir, 3);
  const left = fs.readdirSync(dir).sort();
  assert.deepStrictEqual(left, ['check-run-0.log', 'check-run-1.log', 'check-run-2.log']);
});

test('families are pruned independently', () => {
  const dir = tmpDir();
  for (let i = 0; i < 5; i++) write(dir, `check-run-${i}.log`, i);
  for (let i = 0; i < 5; i++) write(dir, `ask-run-${i}.log`, i);
  pruneRunFiles(dir, 2);
  const left = fs.readdirSync(dir);
  assert.strictEqual(left.filter((n) => n.startsWith('check-run-')).length, 2);
  assert.strictEqual(left.filter((n) => n.startsWith('ask-run-')).length, 2);
});

test('files that are not run output are never touched', () => {
  const dir = tmpDir();
  const keepers = ['kanban.json', 'GOALS.md', 'dailybrief.db', 'projects.json', 'last-run.log'];
  keepers.forEach((n, i) => write(dir, n, i));
  for (let i = 0; i < 30; i++) write(dir, `check-digest-${i}.json`, i);
  pruneRunFiles(dir, 1);
  for (const n of keepers) assert.ok(fs.existsSync(path.join(dir, n)), n + ' survived');
});

test('a folder with fewer files than the limit is left alone', () => {
  const dir = tmpDir();
  write(dir, 'check-run-a.log', 1);
  write(dir, 'check-run-b.log', 2);
  assert.deepStrictEqual(pruneRunFiles(dir, 20), []);
  assert.strictEqual(fs.readdirSync(dir).length, 2);
});

test('a missing folder is not an error', () => {
  assert.deepStrictEqual(pruneRunFiles(path.join(os.tmpdir(), 'dailybrief-nope-xyz'), 5), []);
});
