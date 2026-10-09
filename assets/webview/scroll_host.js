// 父文档负责滚动。各章 iframe 不运行书籍脚本，样式与节点路径互相隔离。
(function () {
  'use strict';
  const host = window.gtScroll = { ready: false, busy: false, frames: [], epoch: 0 };
  const content = () => document.getElementById('content');
  const installStyle = new Function('window', 'document', window.gtStyleSource);
  const send = message => window.flutter_inappwebview.callHandler('scrollHost',
      {...message, request: host.request});
  const nodeAt = (doc, path) => path.reduce((n, i) => n.childNodes[i], doc.body);
  function charRect(doc, node, offset) {
    const range = doc.createRange();
    range.setStart(node, Math.min(offset, node.length));
    range.setEnd(node, Math.min(offset + 1, node.length));
    return range.getBoundingClientRect();
  }
  function frameAtTop() {
    return host.frames.findLast(f => f.offsetTop <= scrollY + 0.01) || host.frames[0];
  }
  host.anchor = () => {
    const frame = frameAtTop();
    if (!frame) return null;
    const doc = frame.contentDocument, y = scrollY - frame.offsetTop;
    if (frame.anchorIndex) return window.gtScrollAnchor.at(frame, y);
    for (const [i, image] of [...doc.images].entries()) {
      const r = image.getBoundingClientRect();
      if (r.top <= y + 0.01 && r.bottom > y && r.height > 0) {
        return {index: frame.meta.index, image: i};
      }
    }
    for (const item of frame.textNodes) {
      const range = doc.createRange(); range.selectNodeContents(item.node);
      const r = range.getBoundingClientRect();
      if (r.height === 0 || r.bottom <= y + 0.001) continue;
      let low = 0, high = item.node.length;
      while (low < high) {
        const mid = (low + high) >> 1;
        if (charRect(doc, item.node, mid).bottom <= y + 0.001) low = mid + 1;
        else high = mid;
      }
      return {index: frame.meta.index, path: item.path, offset: low};
    }
    const last = frame.textNodes.at(-1);
    return last ? {index: frame.meta.index, path: last.path, offset: last.node.length}
      : {index: frame.meta.index, image: 0};
  };
  function localPointY(frame, point) {
    if (!point) return 0;
    const doc = frame.contentDocument;
    const r = point.image !== undefined ? doc.images[point.image].getBoundingClientRect()
      : charRect(doc, nodeAt(doc, point.path), point.offset);
    return r.top;
  }
  host.pointY = point => {
    const frame = host.frames.find(f => f.meta.index === point.index);
    return frame ? frame.offsetTop + localPointY(frame, point) : null;
  };
  host.restore = point => {
    const y = host.pointY(point);
    if (y !== null) scrollTo(0, y);
    return y;
  };
  async function prepare(meta, options, epoch) {
    const started = window.__gtReaderPerf ? performance.now() : 0;
    const frame = document.createElement('iframe');
    frame.sandbox = 'allow-same-origin'; frame.meta = meta;
    // fixed 准备不扩大父文档的滚动范围；长章不能在完成前制造可滑入的空白。
    frame.style.cssText = 'position:fixed;top:0;left:0;opacity:0;pointer-events:none';
    frame.style.order = meta.index;
    const loaded = new Promise((resolve, reject) => {
      frame.onload = resolve; frame.onerror = reject;
    });
    // 插入前指定地址，避免把 about:blank 的首次 load 当成章节已经加载。
    frame.src = meta.url; content().append(frame);
    await loaded;
    if (epoch !== host.epoch) { frame.remove(); return null; }
    const doc = frame.contentDocument, win = frame.contentWindow;
    win.__gtHost = {state: {started: false, margin: options.marginPx}};
    const base = doc.createElement('style');
    base.textContent = (options.fontCss || '') + window.gtBaseCss;
    doc.head.append(base);
    installStyle(win, doc);
    win.__gtHost.style.markImageOnlyParagraphs();
    win.__gtHost.style.markWideHeadings();
    win.__gtHost.style.apply(options);
    const style = doc.createElement('style');
    style.textContent = 'html,body{height:auto!important;margin:0!important;' +
      'overflow:hidden!important;columns:auto!important;transform:none!important}' +
      'body{padding:24px ' + options.marginPx + 'px!important;box-sizing:border-box}' +
      'img,svg,video{max-height:none!important}';
    doc.head.append(style);
    // 与分页模式一样，普通体和粗体就绪后再测量滚动章节高度。
    await win.__gtHost.style.prepareFont(options.fontFamily, '');
    await new Promise(resolve => win.__gtHost.style.whenContentReady(resolve));
    if (epoch !== host.epoch) { frame.remove(); return null; }
    frame.style.height = Math.max(doc.body.scrollHeight, doc.documentElement.scrollHeight) + 'px';
    try {
      frame.textNodes = meta.nodes.map(item => ({path: item.path, node: nodeAt(doc, item.path)}));
    } catch (error) {
      console.log('[R3 paths] ' + JSON.stringify(meta.nodes) + ' body=' + doc.body.innerHTML.slice(0, 500));
      throw error;
    }
    await window.gtScrollAnchor.prepare(frame, () => epoch !== host.epoch);
    if (epoch !== host.epoch) { frame.remove(); return null; }
    doc.addEventListener('click', event => {
      // 原生 WebView 接收短按，统一回到 Flutter 判定；阻止链接自行导航。
      if (event.target.closest('a')) event.preventDefault();
      send({type:'tap', x:event.clientX, y:frame.offsetTop-scrollY+event.clientY});
    });
    doc.addEventListener('touchstart', () => {
      host.completionTouch = true;
      host.speechMotion = (host.speechMotion || 0) + 1;
      host.stopAuto?.(); send({type: 'manual'});
    }, {passive: true});
    host.installSelectionEvents?.(frame);
    if (window.__gtReaderPerf) console.log('GT_READER_PERF ' + JSON.stringify({
      stage: 'original.scroll.prepare', us: Math.round((performance.now() - started) * 1000),
      chapter: meta.index}));
    return frame;
  }
  async function around(available, current, local, options, epoch) {
    const next = [current];
    async function getFrame(i) {
      const held = available.find(f => f.meta.index === i);
      if (held) return held;
      const meta = await send({type:'need', index:i});
      if (epoch !== host.epoch) return null;
      return prepare(meta, options, epoch);
    }
    let above = local, below = current.offsetHeight - local;
    while (next[0].meta.index > 0 &&
        (next.length === 1 || above < innerHeight * 2)) {
      const frame = await getFrame(next[0].meta.index - 1);
      if (!frame) return null;
      next.unshift(frame); above += frame.offsetHeight;
    }
    while (next.at(-1).meta.index + 1 < host.count &&
        (next.at(-1) === current || below < innerHeight * 3)) {
      const frame = await getFrame(next.at(-1).meta.index + 1);
      if (!frame) return null;
      next.push(frame); below += frame.offsetHeight;
    }
    return next;
  }
  host.open = async (metas, point, options) => {
    const epoch = ++host.epoch; host.busy = true;
    try {
      const available = (await Promise.all(metas.map(meta => prepare(meta, options, epoch)))).filter(Boolean);
      if (epoch !== host.epoch) return false;
      const current = available.find(f => f.meta.index === point?.index) || available[0];
      const next = await around(available, current, localPointY(current, point), options, epoch);
      if (!next || epoch !== host.epoch) return false;
      // 已加载的 iframe 不换父节点，移动它会让浏览器重新加载并废弃文字节点。
      for (const frame of host.frames) frame.remove();
      for (const frame of next) {
        frame.style.position = 'static'; frame.style.opacity = '1'; frame.style.pointerEvents = '';
      }
      host.frames = next; host.options = options;
      host.paintDecorations?.();
      if (point) host.restore(point); else scrollTo(0, 0);
      host.center = current.meta.index;
      await send({type:'window', indices:next.map(f => f.meta.index)});
      if (epoch !== host.epoch) return false;
      host.ready = true; send({type: 'ready'});
      return true;
    } finally {
      if (epoch === host.epoch) {
        host.busy = false;
        if (host.ready) host.maintain();
      }
    }
  };
  // 附近跳转复用已经排好的网页；先补足目标周围，再一次替换距离和章节。
  host.seek = async (point, animated = false) => {
    const current = host.frames.find(f => f.meta.index === point.index);
    if (!host.ready || !current) return false;
    host.busy = true;
    const epoch = ++host.epoch;
    for (const frame of [...content().children]) {
      if (!host.frames.includes(frame)) frame.remove();
    }
    try {
      if (animated) {
        // 听书换段保留当前iframe与屏幕，动画期间不提交中间阅读位置。
        const from = scrollY, target = Math.max(0, Math.min(host.pointY(point),
          document.documentElement.scrollHeight - innerHeight));
        const motion = host.speechMotion = (host.speechMotion || 0) + 1;
        await new Promise(resolve => {
          let start;
          function tick(now) {
            if (epoch !== host.epoch || motion !== host.speechMotion) return resolve();
            start ??= now;
            const t = Math.min(1, (now - start) / 320);
            const eased = t < .5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2;
            scrollTo(0, from + (target - from) * eased);
            if (t < 1) requestAnimationFrame(tick); else resolve();
          }
          requestAnimationFrame(tick);
        });
        if (epoch !== host.epoch) return true;
        host.center = current.meta.index;
        host.resetAutoBaseline?.();
        send({type:'ready'});
        return true;
      }
      const next = await around(host.frames, current, localPointY(current, point), host.options, epoch);
      if (!next || epoch !== host.epoch) return false;
      for (const frame of host.frames) if (!next.includes(frame)) frame.remove();
      for (const frame of next) {
        frame.style.position = 'static'; frame.style.opacity = '1'; frame.style.pointerEvents = '';
      }
      host.frames = next; host.center = current.meta.index;
      host.restore(point); host.paintDecorations?.(); host.resetAutoBaseline?.();
      await send({type:'window', indices:next.map(f => f.meta.index)});
      if (epoch !== host.epoch) return false;
      send({type:'ready'});
      return true;
    } finally {
      if (epoch === host.epoch) { host.busy = false; host.maintain(); }
    }
  };
  host.maintain = async () => {
    if (host.busy || !host.ready) return;
    const current = frameAtTop(), index = current.meta.index;
    const total = host.frames.reduce((n, f) => n + f.offsetHeight, 0);
    if (host.center === index &&
        (host.frames[0].meta.index === 0 || scrollY >= innerHeight) &&
        (host.frames.at(-1).meta.index === host.count - 1 || total - scrollY >= innerHeight * 2)) return;
    host.busy = true; const epoch = host.epoch;
    let retry = false;
    try {
      // 封面、版权页很短；按屏幕高度保留余量，不能固定只有三章。
      const next = await around(host.frames, current,
          scrollY - current.offsetTop, host.options, epoch);
      if (!next) return;
      if (epoch !== host.epoch) return;
      // 按完成时的可见章补偿，准备期间继续拖动不会被拉回开始测量的位置。
      const visible = frameAtTop(), oldTop = visible.offsetTop;
      if (!next.includes(visible)) {
        for (const frame of next) if (!host.frames.includes(frame)) frame.remove();
        retry = true;
        return;
      }
      const oldY = scrollY;
      host.center = index;
      for (const frame of host.frames) if (!next.includes(frame)) frame.remove();
      for (const frame of next) {
        frame.style.position = 'static'; frame.style.opacity = '1'; frame.style.pointerEvents = '';
      }
      host.frames = next;
      host.paintDecorations?.();
      scrollTo(0, oldY + visible.offsetTop - oldTop);
      host.resetAutoBaseline?.();
      await send({type:'window', indices:next.map(f => f.meta.index)});
    } catch (error) {
      if (epoch === host.epoch) {
        host.stopAuto?.();
        for (const frame of [...content().children]) if (!host.frames.includes(frame)) frame.remove();
        send({type:'error', message:String(error)});
      }
    } finally {
      if (epoch === host.epoch) {
        host.busy = false; host.report();
        if (retry) queueMicrotask(() => host.maintain());
      }
    }
  };
  host.actionAt = (x, y) => {
    const frame = host.frames.find(f => y + scrollY >= f.offsetTop &&
      y + scrollY < f.offsetTop + f.offsetHeight);
    if (!frame) return null;
    const doc = frame.contentDocument;
    const element = doc.elementFromPoint(x, y + scrollY - frame.offsetTop);
    if (!element) return null;
    const image = element.closest('img,image');
    if (image) {
      const src = image.currentSrc || image.getAttribute('src') ||
        image.getAttribute('href') || image.getAttribute('xlink:href');
      if (src) return {type:'image', index:frame.meta.index,
        href:new URL(src, doc.baseURI).href};
    }
    const link = element.closest('a[href]');
    return link ? {type:'link', index:frame.meta.index,
      href:new URL(link.getAttribute('href'), doc.baseURI).href} : null;
  };
  host.report = () => {
    if (host.ready && !host.busy) send({type: 'position', point: host.anchor()});
  };
  let reporting = false, ended;
  addEventListener('scroll', () => {
    window.gtReaderPerf?.motion('original.scroll');
    if (!reporting) {
      reporting = true;
      setTimeout(() => { reporting = false; host.report(); host.maintain(); }, 180);
    }
    clearTimeout(ended);
    ended = setTimeout(() => { host.report(); send({type: 'settled'});
      if (host.completionTouch && host.ready && !host.busy &&
          host.frames.at(-1)?.meta.index === host.count - 1 &&
          scrollY + innerHeight >= document.documentElement.scrollHeight - 1) {
        host.completionTouch = false; send({type: 'end'});
      } }, 250);
  }, {passive: true});
})();
