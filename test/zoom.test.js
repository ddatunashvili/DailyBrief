const test = require('node:test');
const assert = require('node:assert');
const { ZOOM_STEPS, ZOOM_MIN, ZOOM_MAX, clampZoom, nextZoom } = require('../src/zoom');

test('clampZoom falls back to 100% for unusable values', () => {
  for (const bad of [undefined, null, NaN, 0, -2, 'x', {}]) {
    assert.strictEqual(clampZoom(bad), 1);
  }
});

test('clampZoom keeps a factor inside the ladder', () => {
  assert.strictEqual(clampZoom(0.1), ZOOM_MIN);
  assert.strictEqual(clampZoom(99), ZOOM_MAX);
  assert.strictEqual(clampZoom(1.25), 1.25);
});

test('nextZoom walks one rung at a time', () => {
  assert.strictEqual(nextZoom(1, 1), 1.1);
  assert.strictEqual(nextZoom(1, -1), 0.9);
  assert.strictEqual(nextZoom(1.25, 1), 1.5);
});

test('nextZoom stops at the ends instead of running off the ladder', () => {
  assert.strictEqual(nextZoom(ZOOM_MAX, 1), ZOOM_MAX);
  assert.strictEqual(nextZoom(ZOOM_MIN, -1), ZOOM_MIN);
});

test('nextZoom with dir 0 resets to 100%', () => {
  assert.strictEqual(nextZoom(2.5, 0), 1);
});

test('a factor between rungs snaps to the next real rung', () => {
  assert.strictEqual(nextZoom(1.3, 1), 1.5);
  assert.strictEqual(nextZoom(1.3, -1), 1.25);
});

test('stepping up then down returns to the starting rung', () => {
  for (const start of ZOOM_STEPS.slice(1, -1)) {
    assert.strictEqual(nextZoom(nextZoom(start, 1), -1), start);
  }
});
