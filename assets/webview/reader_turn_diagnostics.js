// 仅手动复现包加载。内存记录，不读DOM几何、不改样式、不逐点输出或跨桥。
(function () {
  'use strict';
  const traces = new Map(), limit = 3072;
  let active = null, frame = null, until = 0;
  const nowUs = () => Math.round(performance.now() * 1000);
  function add(trace, kind, row) {
    if (trace[kind].length < limit) trace[kind].push(row);
    else trace.dropped[kind] = (trace.dropped[kind] || 0) + 1;
  }
  function tick(now) {
    frame = null;
    if (active) add(active, 'frames', [Math.round(now * 1000), nowUs(), active.last]);
    if (performance.now() < until) frame = requestAnimationFrame(tick);
  }
  function get(id) {
    if (!traces.has(id)) {
      if (traces.size === 16) traces.delete(traces.keys().next().value);
      traces.set(id, {calls: [], frames: [], transitions: [], scrolls: [], dropped: {}, last: 0});
    }
    return traces.get(id);
  }
  window.gtReaderTurnDiagnostics = {
    run(id, sequence, action, observeFrames = true) {
      const trace = active = get(id), row = [sequence, nowUs(), 0];
      trace.last = sequence;
      if (observeFrames) {
        until = performance.now() + 400;
        if (frame === null) frame = requestAnimationFrame(tick);
      }
      add(trace, 'calls', row);
      try { return action(); }
      finally { row[2] = nowUs(); }
    },
    take(id) {
      const trace = traces.get(id);
      if (!trace) return null;
      traces.delete(id);
      if (active === trace) active = null;
      return {...trace, readAtUs: nowUs(), visibility: document.visibilityState,
        note: 'rAF and style writes are not physical display timestamps.'};
    }
  };
  window.addEventListener('scroll', () => {
    if (!active) return;
    add(active, 'scrolls', [nowUs(), window.scrollX || 0, window.scrollY || 0]);
    until = performance.now() + 400;
    if (frame === null) frame = requestAnimationFrame(tick);
  }, {passive: true});
  ['transitionrun', 'transitionstart', 'transitionend', 'transitioncancel'].forEach(type => {
    document.addEventListener(type, event => {
      if (active && event.target === document.body && event.propertyName === 'transform') {
        add(active, 'transitions', [type, nowUs(), Math.round(event.timeStamp * 1000),
          Math.round(event.elapsedTime * 1000000)]);
      }
    }, true);
  });
})();
