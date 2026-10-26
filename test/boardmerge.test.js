const test = require('node:test');
const assert = require('node:assert');
const { mergeBoard } = require('../src/boardmerge');

const FIELDS = ['id', 'title', 'desc', 'status', 'done', 'comments', 'aiNotes', 'dirs', 'subtasks', 'updatedAt'];
const task = (id, extra) => Object.assign({ id, title: 'T ' + id, status: 'planning', done: false, comments: [], aiNotes: [] }, extra || {});
const board = (tasks, archive, extra) => Object.assign({ tasks: tasks || [], archive: archive || [] }, extra || {});
const clone = (x) => JSON.parse(JSON.stringify(x));
const merge = (b, m, t) => mergeBoard(b, m, t, { mineFields: FIELDS });
const ids = (list) => list.map((x) => x.id);

test('a task only on the page is added, one only on disk is kept', () => {
  const base = board([task('a')]);
  const mine = board([task('a'), task('new')]);
  const theirs = board([task('a'), task('script')]);
  assert.deepStrictEqual(ids(merge(base, mine, theirs).tasks), ['a', 'script', 'new']);
});

test('deleted on the page: gone, unless a script changed it since', () => {
  const base = board([task('a'), task('b')]);
  const mine = board([]);
  const theirs = board([task('a'), task('b', { aiNotes: [{ at: '2026-01-01', text: 'moved' }] })]);
  assert.deepStrictEqual(ids(merge(base, mine, theirs).tasks), ['b']);
});

test('removed by a script: gone, unless the user edited it since', () => {
  const base = board([task('a'), task('b')]);
  const mine = board([task('a'), task('b', { title: 'edited' })]);
  const theirs = board([]);
  const out = merge(base, mine, theirs);
  assert.deepStrictEqual(ids(out.tasks), ['b']);
  assert.strictEqual(out.tasks[0].title, 'edited');
});

test('page unchanged -> disk wins; disk unchanged -> page wins', () => {
  const base = board([task('a'), task('b')]);
  const mine = board([task('a'), task('b', { status: 'urgent' })]);
  const theirs = board([task('a', { done: true }), task('b')]);
  const out = merge(base, mine, theirs);
  assert.strictEqual(out.tasks[0].done, true);
  assert.strictEqual(out.tasks[1].status, 'urgent');
});

test('both changed: per field, mine where mine changed it, theirs elsewhere', () => {
  const base = board([task('a', { desc: 'old', subtasks: [{ text: 's1', done: false }] })]);
  const mine = board([task('a', { desc: 'old', title: 'renamed', subtasks: [{ text: 's1', done: true }] })]);
  const theirs = board([task('a', { desc: 'by ai', status: 'active', subtasks: [{ text: 's1', done: false }] })]);
  const t = merge(base, mine, theirs).tasks[0];
  assert.strictEqual(t.title, 'renamed');
  assert.strictEqual(t.desc, 'by ai');
  assert.strictEqual(t.status, 'active');
  assert.deepStrictEqual(t.subtasks, [{ text: 's1', done: true }]);
});

test('comments and AI notes from both sides are kept, an ack sticks', () => {
  const c1 = { by: 'user', text: 'do it', at: '2026-01-01T10:00', state: 'new' };
  const base = board([task('a', { comments: [c1] })]);
  const mine = board([task('a', { comments: [c1, { by: 'user', text: 'also this', at: '2026-01-01T11:00', state: 'new' }] })]);
  const theirs = board([task('a', {
    comments: [Object.assign({}, c1, { state: 'applied' }), { by: 'ai', text: 'done', at: '2026-01-01T10:30', state: 'applied' }],
    aiNotes: [{ at: '2026-01-01T10:30', text: 'note' }]
  })]);
  const t = merge(base, mine, theirs).tasks[0];
  assert.deepStrictEqual(t.comments.map((c) => c.text), ['do it', 'done', 'also this']);
  assert.strictEqual(t.comments[0].state, 'applied');
  assert.strictEqual(t.aiNotes.length, 1);
});

test('script-only fields survive a page save that never carries them', () => {
  const base = board([task('a', { lastScan: 'x' })]);
  const mine = board([task('a', { title: 'edited' })]);
  const theirs = board([task('a', { lastScan: 'y' })]);
  const t = merge(base, mine, theirs).tasks[0];
  assert.strictEqual(t.title, 'edited');
  assert.strictEqual(t.lastScan, 'y');
});

test('top-level keys: same rule, and keys the page never sends are kept', () => {
  const base = board([], [], { version: 1 });
  const mine = board([], []);
  const theirs = board([], [], { version: 2, compactedAt: 'today' });
  const out = merge(base, mine, theirs);
  assert.strictEqual(out.version, 2);
  assert.strictEqual(out.compactedAt, 'today');
});

test('archiving on the page wins over a script touching the task', () => {
  const base = board([task('a')]);
  const mine = board([], [task('a', { archivedAt: 'now' })]);
  const theirs = board([task('a', { aiNotes: [{ at: '1', text: 'n' }] })]);
  const out = merge(base, mine, theirs);
  assert.deepStrictEqual(ids(out.tasks), []);
  assert.deepStrictEqual(ids(out.archive), ['a']);
});

test('a sanitizer trim in the base is not mistaken for a user edit', () => {
  const notes = Array.from({ length: 12 }, (_, i) => ({ at: String(i).padStart(2, '0'), text: 'n' + i }));
  const base = board([task('a', { aiNotes: notes, status: 'planning' })]);
  const mine = board([task('a', { aiNotes: notes.slice(-10), status: 'planning' })]);
  const theirs = board([task('a', { aiNotes: notes, status: 'active' })]);
  const normalize = (t) => Object.assign({}, t, { aiNotes: (t.aiNotes || []).slice(-10) });
  const out = mergeBoard(base, mine, theirs, { mineFields: FIELDS, normalize }).tasks[0];
  assert.strictEqual(out.status, 'active');
  assert.strictEqual(out.aiNotes.length, 12);
});

test('nothing changed anywhere -> the board as it is', () => {
  const b = board([task('a'), task('b')], [task('z')]);
  assert.deepStrictEqual(merge(clone(b), clone(b), clone(b)), b);
});
