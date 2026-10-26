// A tiny concurrency limiter: at most `max` jobs in flight, the rest wait in
// arrival order. Lean claude runs are cheap enough to fan out, but three
// PowerShell + node + model processes at once is already plenty on a laptop,
// and the board mutex serializes their writes anyway.
//
//   const limit = createLimiter(3);
//   limit.run(() => somethingReturningAPromise());
//
// run() returns a promise for the job's own result. A job that throws or
// rejects frees its slot like any other, so one bad job never stalls the
// queue. clear() drops the jobs that have not started yet (their promises
// resolve to undefined) - that is what a "stop the whole batch" needs.

function createLimiter(max) {
  const limit = Math.max(1, Math.floor(Number(max)) || 1);
  let active = 0;
  const waiting = [];

  function next() {
    while (active < limit && waiting.length) {
      const job = waiting.shift();
      active++;
      let p;
      try { p = Promise.resolve(job.fn()); } catch (e) { p = Promise.reject(e); }
      p.then(job.resolve, job.reject).finally(() => { active--; next(); });
    }
  }

  function run(fn) {
    return new Promise((resolve, reject) => {
      waiting.push({ fn, resolve, reject });
      next();
    });
  }

  function clear() {
    const dropped = waiting.splice(0, waiting.length);
    dropped.forEach((j) => j.resolve(undefined));
    return dropped.length;
  }

  return {
    run,
    clear,
    get active() { return active; },
    get pending() { return waiting.length; },
    get max() { return limit; }
  };
}

module.exports = { createLimiter };
