// 字体、图片与章高度确定后建立坐标索引。滚动定位只查询目标文字，
// 不在每次180ms位置上报时从章首重新读取所有DOM矩形。
(function () {
  'use strict';
  const perf = (stage, start, details) => {
    if (window.__gtReaderPerf) console.log('GT_READER_PERF ' + JSON.stringify({
      stage, us: Math.round((performance.now() - start) * 1000), ...details}));
  };
  window.gtScrollAnchor = {
    prepare: async function (frame, cancelled) {
      const start = window.__gtReaderPerf ? performance.now() : 0;
      const doc = frame.contentDocument, range = doc.createRange();
      const ends = [], images = [];
      let maximum = -Infinity, slice = performance.now();
      for (const item of frame.textNodes) {
        range.selectNodeContents(item.node);
        const r = range.getBoundingClientRect();
        maximum = Math.max(maximum, r.height > 0 ? r.bottom : -Infinity);
        ends.push(maximum);
        // 长章分批读取；DOM顺序不一定等于视觉顺序，用前缀最大值保留原选择规则。
        if (performance.now() - slice >= 3) {
          await new Promise(resolve => setTimeout(resolve, 0));
          if (cancelled()) return;
          slice = performance.now();
        }
      }
      for (const image of doc.images) {
        const r = image.getBoundingClientRect();
        images.push({top: r.top, bottom: r.bottom, height: r.height});
      }
      frame.anchorIndex = {ends, images};
      perf('original.scroll.index', start, {nodes: ends.length, images: images.length});
    },
    at: function (frame, y) {
      const start = window.__gtReaderPerf ? performance.now() : 0;
      const {ends, images} = frame.anchorIndex;
      const index = frame.meta.index;
      try {
        const image = images.findIndex(r => r.top <= y + .01 && r.bottom > y && r.height > 0);
        if (image >= 0) return {index, image};
        let lo = 0, hi = ends.length;
        while (lo < hi) {
          const mid = (lo + hi) >> 1;
          if (ends[mid] <= y + .001) lo = mid + 1; else hi = mid;
        }
        const item = frame.textNodes[lo];
        if (!item) {
          const last = frame.textNodes.at(-1);
          return last ? {index, path: last.path, offset: last.node.length} : {index, image: 0};
        }
        const range = frame.contentDocument.createRange();
        lo = 0; hi = item.node.length;
        while (lo < hi) {
          const mid = (lo + hi) >> 1;
          range.setStart(item.node, mid);
          range.setEnd(item.node, Math.min(mid + 1, item.node.length));
          if (range.getBoundingClientRect().bottom <= y + .001) lo = mid + 1; else hi = mid;
        }
        return {index, path: item.path, offset: lo};
      } finally {
        perf('original.scroll.anchor', start, {nodes: ends.length});
      }
    }
  };
})();
