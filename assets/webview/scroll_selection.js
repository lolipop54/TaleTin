// 每章自己的 DOM Range；标记层只画底色，不插入正文字符或改变节点路径。
(function () {
  'use strict';
  const host = window.gtScroll;
  const nodeAt = (doc, path) => path.reduce((n, i) => n.childNodes[i], doc.body);
  host.hitText = (x, y) => {
    const frame = host.frames.find(f => y + scrollY >= f.offsetTop &&
      y + scrollY < f.offsetTop + f.offsetHeight);
    if (!frame) return null;
    const doc = frame.contentDocument, local = y + scrollY - frame.offsetTop;
    const range = doc.caretRangeFromPoint(x, local);
    if (!range) return null;
    const item = frame.textNodes.find(n => n.node === range.startContainer);
    return item ? {index: frame.meta.index, path: item.path, offset: range.startOffset} : null;
  };
  function measure(segment) {
    const frame = host.frames.find(f => f.meta.index === segment.index);
    if (!frame) return null;
    const doc = frame.contentDocument, range = doc.createRange();
    range.setStart(nodeAt(doc, segment.from.path), segment.from.offset);
    range.setEnd(nodeAt(doc, segment.to.path), segment.to.offset);
    const rects = [];
    for (const r of range.getClientRects()) {
      if (r.width <= 0 || r.height <= 0) continue;
      const same = rects.find(v => Math.abs(v.top-r.top)<1 && Math.abs(v.bottom-r.bottom)<1);
      if (same) { same.left=Math.min(same.left,r.left); same.right=Math.max(same.right,r.right); }
      else rects.push({left:r.left,top:r.top,right:r.right,bottom:r.bottom});
    }
    rects.sort((a,b) => a.top-b.top || a.left-b.left);
    return {frame, rects};
  }
  host.measureRanges = ranges => ranges.map(segments => {
    const rects = []; let start = null, end = null;
    for (const segment of segments) {
      const measured = measure(segment);
      if (!measured) continue;
      const shift = measured.frame.offsetTop - scrollY;
      const all = measured.rects.map(r => ({...r, top: r.top + shift, bottom: r.bottom + shift}));
      rects.push(...all.filter(r => r.bottom >= 0 && r.top <= innerHeight));
      const first = all[0], last = all.at(-1);
      if (segment.start && first && first.bottom >= 0 && first.bottom <= innerHeight)
        start = {x: first.left, y: first.bottom};
      if (segment.end && last && last.bottom >= 0 && last.bottom <= innerHeight)
        end = {x: last.right, y: last.bottom};
    }
    return {rects, start, end};
  });
  host.decorations = [];
  host.paintDecorations = () => {
    for (const frame of host.frames) {
      const doc = frame.contentDocument;
      let layer = doc.getElementById('gt-scroll-marks');
      if (!layer) {
        layer = doc.createElement('div'); layer.id = 'gt-scroll-marks';
        layer.style.cssText = 'position:absolute;top:0;left:0;pointer-events:none';
        doc.documentElement.append(layer);
      }
      layer.replaceChildren();
    }
    for (const item of host.decorations) {
      for (const segment of item.segments) {
        const measured = measure(segment);
        if (!measured) continue;
        const doc = measured.frame.contentDocument, layer = doc.getElementById('gt-scroll-marks');
        for (const r of measured.rects) {
          const mark = doc.createElement('div');
          mark.style.cssText = `position:absolute;left:${r.left}px;top:${r.top}px;` +
            `width:${r.right-r.left}px;height:${r.bottom-r.top}px;background:${item.color}`;
          layer.append(mark);
        }
        if (item.note && segment.end && measured.rects.length) {
          const last = measured.rects.at(-1), mark = doc.createElement('div');
          mark.style.cssText = `position:absolute;left:${Math.min(last.right+2,innerWidth-18)}px;` +
            `top:${Math.max(0,last.top-4)}px;width:16px;height:12px;border-radius:2px;background:${item.link}`;
          mark.innerHTML = '<span style="position:absolute;left:3px;top:10px;border-top:6px solid '+
            item.link+';border-right:5px solid transparent"></span><span style="position:absolute;'+
            'left:4px;top:4px;width:8px;height:3px;border-top:1px solid white;border-bottom:1px solid white"></span>';
          layer.append(mark);
        }
      }
    }
  };
  host.setDecorations = items => { host.decorations = items; host.paintDecorations(); };
  host.installSelectionEvents = frame => {
    // 长按统一由 Flutter 识别；网页只阻止浏览器自己的选文菜单。
    frame.contentDocument.addEventListener('contextmenu', event => event.preventDefault());
  };
})();
