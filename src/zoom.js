// The zoom ladder a browser walks with Ctrl +/-/0. Pure arithmetic, kept
// apart from the window wiring so both the app and the tests can use it.

const ZOOM_STEPS = [0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3];
const ZOOM_MIN = ZOOM_STEPS[0];
const ZOOM_MAX = ZOOM_STEPS[ZOOM_STEPS.length - 1];

// Anything unusable (NaN, 0, a string, a stored value from an older ladder)
// lands on 100% rather than propagating into setZoomFactor.
function clampZoom(value) {
  const v = Number(value);
  if (!isFinite(v) || v <= 0) return 1;
  return Math.min(ZOOM_MAX, Math.max(ZOOM_MIN, v));
}

// Next rung up or down from wherever the current factor sits; dir 0 resets.
// The epsilon keeps a factor that IS a rung from picking itself again.
function nextZoom(current, dir) {
  const cur = clampZoom(current);
  if (dir > 0) {
    const next = ZOOM_STEPS.find((s) => s > cur + 0.001);
    return next === undefined ? ZOOM_MAX : next;
  }
  if (dir < 0) {
    const prev = ZOOM_STEPS.filter((s) => s < cur - 0.001).pop();
    return prev === undefined ? ZOOM_MIN : prev;
  }
  return 1;
}

module.exports = { ZOOM_STEPS, ZOOM_MIN, ZOOM_MAX, clampZoom, nextZoom };
