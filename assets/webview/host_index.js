/* 完整 DOM 不裁剪。先证明目标窗口存在，再分批读取整章几何；补索引不移动页面。 */
(function () {
  'use strict';
  var internal = window.__gtHost, state = internal.state;
  var generation = 0, scan = null, timer = null, background = false;
  var candidates = new Map(), candidateVersion = -1;
  var costs = {maxUnitMs: 0, maxBatchMs: 0, units: 0};
  var blocks = new Set('P H1 H2 H3 H4 H5 H6 LI DIV IMG TABLE PRE BLOCKQUOTE FIGURE SECTION ARTICLE'.split(' '));
  var media = new Set('IMG SVG VIDEO TABLE HR FIGURE'.split(' '));

  function cancel() {
    generation++;
    clearTimeout(timer); timer = null; scan = null;
  }

  function yieldTask() { return new Promise(function (resolve) { setTimeout(resolve, 0); }); }

  function addRect(rect, occupied) {
    if (!rect.width && !rect.height) return;
    var first = Math.max(0, Math.floor(rect.left / state.width));
    var last = Math.max(first, Math.ceil(rect.right / state.width) - 1);
    for (var page = first; page <= last; page++) occupied.add(page);
  }

  function remember(node, rect, text) {
    if (!rect.width && !rect.height) return;
    if (internal.content && !internal.content.hasNode(node)) return;
    var first = Math.max(0, Math.floor(rect.left / state.width));
    var last = Math.max(first, Math.ceil(rect.right / state.width) - 1);
    for (var page = first; page <= last; page++) {
      var pair = candidates.get(page) || {};
      var key = text ? 'text' : 'media', old = pair[key];
      if (!old || (text ? node.compareDocumentPosition(old.node) & 4 : rect.top < old.rect.top)) {
        pair[key] = {node: node, rect: rect}; candidates.set(page, pair);
      }
    }
  }

  function visit(node, result, onlyContent, from, to) {
    var started = performance.now();
    try { readGeometry(node, result, onlyContent, from, to); }
    finally {
      costs.units++;
      costs.maxUnitMs = Math.max(costs.maxUnitMs, performance.now() - started);
    }
  }

  function readGeometry(node, result, onlyContent, from, to) {
    var rects, tag = (node.tagName || '').toUpperCase();
    if (node.nodeType === 3) {
      if (!node.nodeValue || !node.nodeValue.trim()) return;
      rects = from === undefined ? internal.layout.textRects(node) :
        internal.layout.textRangeRects(node, from, to);
      for (var i = 0; i < rects.length; i++) {
        var r = rects[i];
        if (!r.width && !r.height) continue;
        result.right = Math.max(result.right, r.right);
        addRect(r, result.occupied);
        remember(node, r, true);
      }
    } else if (media.has(tag) || tag === 'IMAGE' || (!onlyContent && blocks.has(tag))) {
      var box = internal.layout.elementRect(node);
      if (!box.width && !box.height) return;
      result.right = Math.max(result.right, box.right);
      if (media.has(tag) || tag === 'IMAGE') addRect(box, result.occupied);
      if (tag === 'IMG' || tag === 'IMAGE') remember(node, box, false);
    }
  }

  function walker() {
    return document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT | NodeFilter.SHOW_ELEMENT, null);
  }

  // 不修改正文节点。超长单段按 Range 偏移读取，不能把一次巨大 getClientRects
  // 藏在“每批1.5ms”内。目标所在段先从目标字符附近读取，后台仍按源码顺序读取。
  function* pieces(node, offset) {
    if (node.nodeType !== 3 || node.length <= 2048) { yield {node: node}; return; }
    var center = Math.floor(Math.max(0, Math.min(node.length - 1, offset || 0)) / 2048);
    var count = Math.ceil(node.length / 2048);
    for (var distance = 0; distance < count; distance++) {
      var indexes = distance === 0 ? [center] : [center + distance, center - distance];
      for (var i = 0; i < indexes.length; i++) {
        var at = indexes[i];
        if (at >= 0 && at < count) yield {node: node, from: at * 2048,
          to: Math.min(node.length, (at + 1) * 2048)};
      }
    }
  }

  function readPiece(piece, result, onlyContent) {
    visit(piece.node, result, onlyContent, piece.from, piece.to);
  }

  // 空白栏可能是合法的 break-before，未找到文字绝不直接当书末。
  // 近邻探测无法证明窗口时，在揭开前回退到原来的完整测量。
  async function prepare(point) {
    cancel();
    costs = {maxUnitMs: 0, maxBatchMs: 0, units: 0};
    internal.layout.invalidate();
    candidates.clear(); candidateVersion = internal.layout.geometryVersion();
    var id = generation, page = internal.dom.pageOfPoint(point);
    var node = internal.dom.nodeOfPoint(point);
    if (page === null || !node) return false;
    var found = await localWindow(point);
    if (!found || id !== generation) return false;
    state.indexComplete = false;
    state.pages = Math.max(page + 5, Math.ceil(found.right / state.width));
    state.scrollWidth = document.body.scrollWidth;
    var range = document.createRange(); range.selectNodeContents(document.body);
    var bounds = range.getBoundingClientRect();
    scan = {id: id, version: internal.layout.geometryVersion(), walker: walker(), pending: null,
      right: Math.max(state.scrollWidth, bounds.width ? internal.layout.toContentX(bounds.right) : 0),
      occupied: new Set(), done: false};
    state.contentWidth = scan.right;
    internal.post('turnTrace', {stage: 'target-window-ready', page: page,
      knownPages: state.pages, nodes: found.count, ms: performance.now()});
    return true;
  }

  async function localWindow(point) {
    var id = generation, page = internal.dom.pageOfPoint(point);
    var node = internal.dom.nodeOfPoint(point);
    if (page === null || !node) return null;
    var found = {right: 0, occupied: new Set()};
    var before = walker(), after = walker();
    before.currentNode = node; after.currentNode = node;
    var wanted = [];
    for (var p = Math.max(0, page - 1); p <= page + 4; p++) wanted.push(p);
    function ready() { return wanted.every(function (p) { return found.occupied.has(p); }); }
    function* nearby() {
      yield* pieces(node, point.offset);
      var next = node, previous = node;
      while (next || previous) {
        next = after.nextNode(); previous = before.previousNode();
        if (next) yield* pieces(next);
        if (previous) yield* pieces(previous);
      }
    }
    var count = 0, stream = nearby(), item = stream.next();
    while (!ready() && count < 1024 && !item.done) {
      var start = performance.now();
      do {
        readPiece(item.value, found, true);
        count++; item = stream.next();
      } while (!ready() && count < 1024 && !item.done && performance.now() - start < 2);
      costs.maxBatchMs = Math.max(costs.maxBatchMs, performance.now() - start);
      if (id !== generation) return null;
      if (!ready()) await yieldTask();
    }
    if (!ready()) return null;
    return {page: page, right: found.right, count: count};
  }

  async function ensureWindow(point) {
    if (state.indexComplete) return true;
    var page = internal.dom.pageOfPoint(point);
    if (page === null) return false;
    if (page + 4 < state.pages) return true;
    var id = generation, found = await localWindow(point);
    if (id !== generation) return false;
    if (found) state.pages = Math.max(state.pages, found.page + 5, Math.ceil(found.right / state.width));
    else await ensure(Infinity);
    return true;
  }

  function advance() {
    var work = scan;
    if (!work || work.done) return;
    if (work.version !== internal.layout.geometryVersion()) {
      // 样式、视口或真实资源变化由现有 relayout 入口处理。
      // 后台不偷偷执行一次完整同步 measure，更不能发布旧几何的页数。
      cancel();
      return;
    }
    var start = performance.now(), node, item;
    do {
      item = work.pending && work.pending.next();
      if (!item || item.done) {
        node = work.walker.nextNode();
        if (!node) break;
        work.pending = pieces(node); item = work.pending.next();
      }
      if (!item.done) readPiece(item.value, work, false);
    } while (performance.now() - start < 1.5);
    costs.maxBatchMs = Math.max(costs.maxBatchMs, performance.now() - start);
    // 最大已证实页只扩展，不改变当前页；中间的合法空白栏照常存在。
    work.occupied.forEach(function (p) { state.pages = Math.max(state.pages, p + 1); });
    if (node !== null) return;
    var pages = Math.max(1, Math.round(work.right / state.width));
    while (pages < 500 && work.occupied.has(pages)) pages++;
    while (pages > 1 && !work.occupied.has(pages - 1)) pages--;
    if (pages < state.pages) {
      // 正文有变或几何不一致，不允许后台把可见页悄悄夹到另一页。
      internal.post('error', {message: '原书目标窗口与完整索引不一致'});
      cancel(); return;
    }
    state.pages = pages;
    state.contentWidth = work.right;
    state.indexComplete = true; work.done = true;
    internal.layout.seedIndex(work.right, work.occupied);
    internal.post('indexReady', {pages: pages, page: state.page});
    if (window.__gtTraceTurn) internal.post('turnTrace', {stage: 'index-cost',
      units: costs.units, maxUnitMs: costs.maxUnitMs, maxBatchMs: costs.maxBatchMs,
      ms: performance.now()});
  }

  function pump() {
    if (timer || !background || !scan || scan.done) return;
    timer = setTimeout(function () {
      timer = null;
      if (!background) return;
      advance(); pump();
    }, 8);
  }

  async function ensure(page) {
    if (page < 0) return false;
    while (!state.indexComplete && page >= state.pages) {
      if (!scan) throw new Error('原书索引已失效');
      advance();
      if (!state.indexComplete && page >= state.pages) await yieldTask();
    }
    return page < state.pages;
  }

  function pathOf(node) {
    var path = [];
    while (node && node !== document.body) {
      var parent = node.parentNode;
      if (!parent) return null;
      path.push(Array.prototype.indexOf.call(parent.childNodes, node)); node = parent;
    }
    return node ? path.reverse() : null;
  }

  function pointForPage(page, geometryOnly) {
    if (!geometryOnly && page === state.page && internal.selection) {
      var visible = internal.selection.scanPageAnchor();
      if (visible) return visible;
    }
    var version = internal.layout.geometryVersion();
    if (candidateVersion !== version) {
      candidates.clear(); candidateVersion = version;
    }
    if (!candidates.has(page) && state.indexComplete) {
      var all = walker(), n, result = {right: 0, occupied: new Set()};
      while ((n = all.nextNode())) visit(n, result, true);
    }
    var pair = candidates.get(page);
    if (!pair) return null;
    var text = pair.text, point = null, glyph = null;
    if (text) {
      var node = text.node, low = 0, high = node.length, range = document.createRange();
      while (low < high) {
        var mid = (low + high) >> 1;
        range.setStart(node, mid); range.setEnd(node, Math.min(node.length, mid + 1));
        if (internal.layout.toContentX(range.getBoundingClientRect().left) < page * state.width - 1) low = mid + 1;
        else high = mid;
      }
      if (low < node.length) {
        range.setStart(node, low); range.setEnd(node, low + 1);
        glyph = range.getBoundingClientRect();
        point = {path: pathOf(node), offset: low};
      }
    }
    if (pair.media && (!glyph || pair.media.rect.top < glyph.top)) {
      return {path: pathOf(pair.media.node), element: true};
    }
    return point;
  }

  internal.index = {prepare: prepare, ensure: ensure, ensureWindow: ensureWindow, cancel: cancel, pointForPage: pointForPage,
    setBackground: function (value) {
      background = value === true;
      if (!background) { clearTimeout(timer); timer = null; }
      else pump();
    }};
})();
