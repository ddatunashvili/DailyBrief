const test = require('node:test');
const assert = require('node:assert');
const { shardByProject, NO_PROJECT } = require('../src/shard');

const t = (id, dirs, extra) => Object.assign({ id, title: id, dirs: dirs || [] }, extra || {});

test('one group per project folder, biggest first, folderless last', () => {
  const shards = shardByProject([
    t('n1'),
    t('a1', ['C:\\code\\alpha']),
    t('b1', ['C:\\code\\beta']),
    t('b2', ['C:\\code\\beta\\']),
    t('n2', [])
  ]);
  assert.deepStrictEqual(shards.map((s) => [s.name, s.ids]), [
    ['beta', ['b1', 'b2']],
    ['alpha', ['a1']],
    [NO_PROJECT, ['n1', 'n2']]
  ]);
});

test('done tasks and tasks without an id are left out', () => {
  const shards = shardByProject([t('a', ['C:\\x']), t('b', ['C:\\x'], { done: true }), { dirs: ['C:\\x'] }, null]);
  assert.deepStrictEqual(shards.map((s) => s.ids), [['a']]);
});

test('the first linked folder decides, case-insensitively', () => {
  const shards = shardByProject([
    t('a', ['C:\\Code\\App', 'C:\\other']),
    t('b', ['c:\\code\\app'])
  ]);
  assert.strictEqual(shards.length, 1);
  assert.deepStrictEqual(shards[0].ids, ['a', 'b']);
});

test('two repos with the same folder name stay apart', () => {
  const shards = shardByProject([t('a', ['C:\\work\\api']), t('b', ['D:\\side\\api'])]);
  assert.strictEqual(shards.length, 2);
  assert.ok(shards.every((s) => s.name === 'api'));
});

test('a project bigger than the per-run cap is split', () => {
  const tasks = Array.from({ length: 5 }, (_, i) => t('x' + i, ['C:\\big']));
  const shards = shardByProject(tasks, 2);
  assert.deepStrictEqual(shards.map((s) => s.ids.length), [2, 2, 1]);
});

test('an empty or broken board yields no shards', () => {
  assert.deepStrictEqual(shardByProject([]), []);
  assert.deepStrictEqual(shardByProject(null), []);
});
