const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const R = require('../src/roots');

const HOME = 'C:\\Users\\u';

test('defaultRoots mirrors core\\roots.ps1 order, Downloads only on request', () => {
  const d = R.defaultRoots({ desktop: 'C:\\Users\\u\\OneDrive\\Desktop\\', documents: 'C:\\Users\\u\\Documents', home: HOME });
  assert.deepStrictEqual(d, [
    'C:\\Users\\u\\OneDrive\\Desktop', 'C:\\Users\\u\\Documents',
    'C:\\Users\\u\\OneDrive\\Desktop', 'C:\\Users\\u\\OneDrive\\Documents',
    'C:\\Users\\u\\Desktop', 'C:\\Users\\u\\Documents',
    'C:\\Users\\u\\source', 'C:\\Users\\u\\projects'
  ]);
  const w = R.defaultRoots({ home: HOME, withDownloads: true });
  assert.strictEqual(w[w.length - 1], 'C:\\Users\\u\\Downloads');
});

test('effectiveRoots: user first, case-insensitive dedupe, missing dropped', () => {
  const exists = (p) => !/gone/i.test(p);
  const r = R.effectiveRoots(['G:\\Desktop\\', 'g:\\desktop', 'G:\\gone'],
    ['C:\\Users\\u\\Desktop', 'C:\\USERS\\U\\DESKTOP', 'C:\\Users\\u\\gone'], exists);
  assert.deepStrictEqual(r, ['G:\\Desktop', 'C:\\Users\\u\\Desktop']);
});

test('parseRootsJson tolerates BOM, junk and bad JSON', () => {
  assert.deepStrictEqual(R.parseRootsJson('\uFEFF{"roots":["G:\\\\Desktop",5,"g:\\\\DESKTOP\\\\"]}'), ['G:\\Desktop']);
  assert.deepStrictEqual(R.parseRootsJson('nope'), []);
  assert.deepStrictEqual(R.parseRootsJson('{"roots":"G:\\\\x"}'), []);
});

test('isAcceptableRoot refuses drive roots and relative paths', () => {
  assert.strictEqual(R.isAcceptableRoot('G:\\Desktop'), true);
  assert.strictEqual(R.isAcceptableRoot('\\\\nas\\share\\work'), true);
  assert.strictEqual(R.isAcceptableRoot('G:\\'), false);
  assert.strictEqual(R.isAcceptableRoot('G:'), false);
  assert.strictEqual(R.isAcceptableRoot('Desktop'), false);
  assert.strictEqual(R.isAcceptableRoot('G:\\a|b'), false);
});

test('cleanUserRoots keeps only acceptable existing dirs, deduped', () => {
  const exists = (p) => p.toLowerCase() !== 'g:\\missing';
  assert.deepStrictEqual(
    R.cleanUserRoots(['G:\\Desktop', 'g:\\DESKTOP\\', 'G:\\missing', 'G:\\', null, 'rel'], exists),
    ['G:\\Desktop']
  );
});

test('describeRoots flags missing user entries and hides duplicated defaults', () => {
  const exists = (p) => !/gone/i.test(p);
  const d = R.describeRoots(['G:\\Desktop', 'G:\\gone', 'C:\\Users\\u\\Desktop'],
    ['C:\\Users\\u\\desktop', 'C:\\Users\\u\\Documents', 'C:\\Users\\u\\gone'], exists);
  assert.deepStrictEqual(d.user, [
    { dir: 'G:\\Desktop', missing: false }, { dir: 'G:\\gone', missing: true },
    { dir: 'C:\\Users\\u\\Desktop', missing: false }
  ]);
  assert.deepStrictEqual(d.builtin, ['C:\\Users\\u\\Documents']);
});

test('writeRootsFile writes BOM-less JSON atomically and readRootsFile reads it back', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dailybrief-roots-'));
  try {
    const f = path.join(dir, 'roots.json');
    fs.writeFileSync(f, 'old');
    R.writeRootsFile(f, ['G:\\Desktop']);
    const buf = fs.readFileSync(f);
    assert.notStrictEqual(buf[0], 0xEF);
    assert.deepStrictEqual(JSON.parse(buf.toString('utf8')), { roots: ['G:\\Desktop'] });
    assert.deepStrictEqual(R.readRootsFile(f), ['G:\\Desktop']);
    assert.deepStrictEqual(fs.readdirSync(dir), ['roots.json']);
    assert.deepStrictEqual(R.readRootsFile(path.join(dir, 'none.json')), []);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});
