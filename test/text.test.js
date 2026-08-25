const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { listDates, fixMojibake, deepFixMojibake, readJson } = require('../src/text');

// What the old corrupter did: UTF-8 bytes read back as Windows-1252. Only
// 0x80-0x9F differ from Latin-1, and those are exactly the bytes Georgian
// UTF-8 is full of, which is why the damage looked the way it did.
const CP1252_HIGH = {
  0x80: 0x20AC, 0x82: 0x201A, 0x83: 0x0192, 0x84: 0x201E, 0x85: 0x2026,
  0x86: 0x2020, 0x87: 0x2021, 0x88: 0x02C6, 0x89: 0x2030, 0x8A: 0x0160,
  0x8B: 0x2039, 0x8C: 0x0152, 0x8E: 0x017D, 0x91: 0x2018, 0x92: 0x2019,
  0x93: 0x201C, 0x94: 0x201D, 0x95: 0x2022, 0x96: 0x2013, 0x97: 0x2014,
  0x98: 0x02DC, 0x99: 0x2122, 0x9A: 0x0161, 0x9B: 0x203A, 0x9C: 0x0153,
  0x9E: 0x017E, 0x9F: 0x0178
};

function corrupt(s) {
  let out = '';
  for (const b of Buffer.from(s, 'utf8')) out += String.fromCharCode(CP1252_HIGH[b] || b);
  return out;
}

test('mojibake round-trips back to the original Georgian', () => {
  const src = 'დღიური ბრიფინგი';
  const broken = corrupt(src);
  assert.notStrictEqual(broken, src);
  assert.strictEqual(fixMojibake(broken), src);
});

test('clean text is returned untouched', () => {
  for (const s of ['plain ascii', 'დღიური ბრიფინგი', '', 'a']) {
    assert.strictEqual(fixMojibake(s), s);
  }
});

test('deepFixMojibake returns the same reference when nothing changed', () => {
  const obj = { a: 'ok', b: ['დღე', 1, null], c: { d: true } };
  assert.strictEqual(deepFixMojibake(obj), obj);
});

test('deepFixMojibake repairs nested strings', () => {
  const obj = { tasks: [{ title: corrupt('ტასკის სათაური') }] };
  const fixed = deepFixMojibake(obj);
  assert.notStrictEqual(fixed, obj);
  assert.strictEqual(fixed.tasks[0].title, 'ტასკის სათაური');
});

test('readJson strips the BOM the PowerShell side writes', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dailybrief-text-'));
  const p = path.join(dir, 'x.json');
  fs.writeFileSync(p, '﻿{"a":1}', 'utf8');
  assert.deepStrictEqual(readJson(p), { a: 1 });
});

test('readJson returns null for missing or broken files', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dailybrief-text-'));
  assert.strictEqual(readJson(path.join(dir, 'nope.json')), null);
  const bad = path.join(dir, 'bad.json');
  fs.writeFileSync(bad, '{not json');
  assert.strictEqual(readJson(bad), null);
});

test('listDates picks up only date-stamped files with the right extension', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dailybrief-text-'));
  for (const n of ['2026-08-24.json', '2026-08-25.json', 'kanban.json', '2026-08-25.md', 'notadate.json']) {
    fs.writeFileSync(path.join(dir, n), '{}');
  }
  assert.deepStrictEqual(listDates(dir, '.json').sort(), ['2026-08-24', '2026-08-25']);
  assert.deepStrictEqual(listDates(dir, '.md'), ['2026-08-25']);
  assert.deepStrictEqual(listDates(path.join(dir, 'missing'), '.json'), []);
});
