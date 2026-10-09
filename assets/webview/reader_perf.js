// 专项包使用，普通包不开启。rAF间隔反映浏览器回调节奏，不等于屏幕呈现时间。
(function () {
  'use strict';
  if (!window.__gtReaderPerf) return;
  let frame = null, until = 0, previous = null, label = '', gaps = [];
  function log(stage, us, details = {}) {
    console.log('GT_READER_PERF ' + JSON.stringify({stage, us, ...details}));
  }
  function flush() {
    if (gaps.length) {
      gaps.sort((a, b) => a - b);
      log(label + '.raf', 0, {count: gaps.length,
        intervalP95Us: Math.round(gaps[Math.ceil(gaps.length * .95) - 1] * 1000),
        intervalMaxUs: Math.round(gaps.at(-1) * 1000)});
    }
    gaps = []; previous = null;
  }
  function tick(now) {
    if (now > until) {frame = null; flush(); return;}
    if (previous !== null) gaps.push(now - previous);
    previous = now;
    if (gaps.length >= 60) flush();
    frame = requestAnimationFrame(tick);
  }
  window.gtReaderPerf = {
    step(stage, start, details) {log(stage, Math.round((performance.now() - start) * 1000), details);},
    motion(mode) {
      label = mode; until = performance.now() + 300;
      if (frame === null) frame = requestAnimationFrame(tick);
    }
  };
})();
