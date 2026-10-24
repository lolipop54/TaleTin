/* WebView 宿主页内部的分栏、测量与页序能力。 */
(function () {
  'use strict';
  var internal = window.__gtHost = window.__gtHost || {};
  var state = internal.state;
  if (state.indexComplete === undefined) state.indexComplete = true;
  var relocateTimer = null;
  var turnEffect = 'slide';
  var pageProbes = new Map();
  var geometryVersion = 0;
  var geometryValues = new Map();
  var elementRects = new WeakMap(), nodeRects = new WeakMap();
  var elementCount = 0, textRectCount = 0;
  var observer = null, watching = false;

  // 只读取已缓存的排版数字与窗口属性，不增加正文测量或rAF。
  internal.recovery = function (event) {
    if (!window.__gtRecovery) return;
    internal.post('recovery', {event: event, ms: performance.now(),
      page: state.page, pages: state.pages, width: state.width,
      columnWidth: state.columnWidth, margin: state.margin,
      contentWidth: state.contentWidth, scrollWidth: state.scrollWidth,
      innerWidth: window.innerWidth, innerHeight: window.innerHeight,
      visibility: document.visibilityState});
  };
  if (window.__gtRecovery) {
    window.addEventListener('resize', function () { internal.recovery('windowResize'); });
    document.addEventListener('visibilitychange', function () { internal.recovery('visibility'); });
  }

  function contentChanged(records) {
    return records.some(function (record) {
      var target = record.target;
      return target === document.body || (document.body && document.body.contains(target));
    });
  }

  function invalidate() {
    geometryVersion++;
    geometryValues.clear(); pageProbes.clear();
    elementRects = new WeakMap(); nodeRects = new WeakMap();
    elementCount = 0; textRectCount = 0;
  }

  function checkGeometry() {
    if (!watching && document.body) {
      watching = true;
      if (window.MutationObserver) {
        observer = new window.MutationObserver(function (records) {
          if (contentChanged(records)) invalidate();
        });
        // Reader style writes invalidate explicitly. Exclude body transform/style
        // attributes so a page translation does not destroy content coordinates.
        observer.observe(document.documentElement || document.body, {
          subtree: true, childList: true, characterData: true,
          attributes: true, attributeFilter: ['src', 'width', 'height', 'class', 'hidden']
        });
      }
      window.addEventListener?.('resize', invalidate);
      document.addEventListener?.('load', invalidate, true);
      document.addEventListener?.('error', invalidate, true);
      document.fonts?.addEventListener?.('loadingdone', invalidate);
      document.fonts?.addEventListener?.('loadingerror', invalidate);
    }
    // Mutations may still be queued in this task when a coordinate is requested.
    if (observer && contentChanged(observer.takeRecords())) invalidate();
    return geometryVersion;
  }

  function cachedValue(key, compute) {
    checkGeometry();
    if (!geometryValues.has(key)) geometryValues.set(key, compute());
    return geometryValues.get(key);
  }

  function contentRect(rect) {
    return { left: toContentX(rect.left), right: toContentX(rect.right),
      width: rect.width, height: rect.height, top: rect.top, bottom: rect.bottom };
  }

  function elementRect(element) {
    var rect = elementRects.get(element);
    if (!rect) {
      rect = contentRect(element.getBoundingClientRect());
      if (elementCount < 4096) { elementRects.set(element, rect); elementCount++; }
    }
    return rect;
  }

  function textRects(node) {
    var rects = nodeRects.get(node);
    if (!rects) {
      var range = document.createRange();
      range.selectNodeContents(node);
      rects = Array.from(range.getClientRects(), contentRect);
      // A very long paragraph still works without retaining an unbounded array.
      if (textRectCount + rects.length <= 12000) {
        nodeRects.set(node, rects); textRectCount += rects.length;
      }
    }
    return rects;
  }

  function textRangeRects(node, from, to) {
    var range = document.createRange();
    range.setStart(node, from); range.setEnd(node, to);
    return Array.from(range.getClientRects(), contentRect);
  }

  // 分栏时已校正页数，章内翻页直接查范围；末页纠错每次排版只探测一次。
  function probePage(page) {
    checkGeometry();
    if (!pageProbes.has(page)) {
      pageProbes.set(page, hasContentAt(page * state.width));
    }
    return pageProbes.get(page);
  }

  function hasPage(page) {
    return page >= 0 && (page < state.pages || probePage(page));
  }

  // 视口坐标换算为不受当前页平移影响的内容坐标。
  function toContentX(clientX) {
    return clientX + state.page * state.width;
  }

  function columnStep() {
    return cachedValue('columnStep', measureColumnStep);
  }

  function measureColumnStep() {
    var blocks = document.body.querySelectorAll('p,h1,h2,h3,h4,h5,h6,div,li');
    var first = -1;
    for (var i = 0; i < blocks.length; i++) {
      var rect = elementRect(blocks[i]);
      if (!rect || !rect.width) continue;
      var left = rect.left;
      if (first < 0) { first = left; continue; }
      var delta = left - first;
      if (delta > 10) return Math.round(delta);
    }
    return 0;
  }

  function updateTransformHint() {
    if (document.body) document.body.style.setProperty(
      'will-change', turnEffect === 'slide' ? 'transform' : 'auto');
  }

  function setupColumns() {
    invalidate();
    var body = document.body;
    var root = document.documentElement;
    if (!body) return;
    var margin = Math.max(0, state.margin || 0);
    // 页序仍指一屏；双页把一屏分成两栏，DOM定位、选文和书签继续用真实坐标。
    state.columnWidth = Math.max(1, state.width / (window.__gtInformation.spread() ? 2 : 1) - margin * 2);
    var width = state.columnWidth + 'px';
    var gap = (margin * 2) + 'px';
    root.style.setProperty('height', '100%');
    root.style.setProperty('overflow', 'hidden');
    root.style.setProperty('--gt-content-height',
      'calc(100vh - ' + window.__gtInformation.insets() + 'px)');
    body.style.setProperty('height',
      'calc(100% - ' + window.__gtInformation.insets() + 'px)', 'important');
    body.style.setProperty('position', 'relative', 'important');
    body.style.setProperty('top', window.__gtInformation.top() + 'px', 'important');
    body.style.setProperty('box-sizing', 'content-box', 'important');
    body.style.setProperty('width', width, 'important');
    body.style.setProperty('padding-left', margin + 'px', 'important');
    body.style.setProperty('padding-top', '0px', 'important');
    body.style.setProperty('padding-bottom', '0px', 'important');
    body.style.setProperty('padding-right', '0px', 'important');
    body.style.setProperty('margin', '0');
    body.style.setProperty('overflow', 'visible');
    body.style.setProperty('transform-origin', '0 0');
    updateTransformHint();
    body.style.setProperty('column-width', width);
    body.style.setProperty('-webkit-column-width', width);
    body.style.setProperty('column-gap', gap);
    body.style.setProperty('-webkit-column-gap', gap);
    body.style.setProperty('column-fill', 'auto');
    body.style.setProperty('-webkit-column-fill', 'auto');
    // Resize may change the column width while the body still has the previous
    // translation. Align it before saving content coordinates for this layout.
    body.style.setProperty('transition', 'none');
    body.style.setProperty('transform',
      'translateX(' + (-state.page * state.width) + 'px)');
  }

  function contentWidth() {
    return cachedValue('contentWidth', measureContentWidth);
  }

  function measureContentWidth() {
    var maxRight = 0;
    var blocks = document.body.querySelectorAll(
      'p,h1,h2,h3,h4,h5,h6,li,div,img,table,pre,blockquote,figure,section,article');
    for (var i = 0; i < blocks.length; i++) {
      var rect = elementRect(blocks[i]);
      if (!rect || (!rect.width && !rect.height)) continue;
      var right = rect.right;
      if (right > maxRight) maxRight = right;
    }
    try {
      var range = document.createRange();
      range.selectNodeContents(document.body);
      var bounds = range.getBoundingClientRect();
      if (bounds && bounds.width) {
        var rangeRight = toContentX(bounds.right);
        if (rangeRight > maxRight) maxRight = rangeRight;
      }
    } catch (error) {
      // Range 不可用时使用块级测量结果。
    }
    return maxRight;
  }

  function hasContentAt(contentX) {
    checkGeometry();
    var pageEnd = contentX + state.width;
    try {
      var walker = document.createTreeWalker(
        document.body, NodeFilter.SHOW_TEXT, null);
      var node;
      while ((node = walker.nextNode())) {
        if (!node.nodeValue || !node.nodeValue.trim()) continue;
        var rects = textRects(node);
        for (var i = 0; i < rects.length; i++) {
          var rect = rects[i];
          if (!rect.width && !rect.height) continue;
          var left = rect.left;
          var right = rect.right;
          if (left >= contentX && left < pageEnd) return true;
          if (left < contentX && right > contentX) return true;
        }
      }
      var media = document.body.querySelectorAll(
        'img,svg,video,table,hr,figure');
      for (var j = 0; j < media.length; j++) {
        var mediaRect = elementRect(media[j]);
        if (!mediaRect || (!mediaRect.width && !mediaRect.height)) continue;
        var mediaLeft = mediaRect.left;
        var mediaRight = mediaRect.right;
        if (mediaLeft >= contentX && mediaLeft < pageEnd) return true;
        if (mediaLeft < contentX && mediaRight > contentX) return true;
      }
    } catch (error) {
      // 探测失败时由宽度估算兜底。
    }
    return false;
  }

  function textMaxRight() {
    return cachedValue('textMaxRight', measureTextMaxRight);
  }

  function measureTextMaxRight() {
    var maxRight = 0;
    try {
      var walker = document.createTreeWalker(
        document.body, NodeFilter.SHOW_TEXT, null);
      var node;
      while ((node = walker.nextNode())) {
        if (!node.nodeValue || !node.nodeValue.trim()) continue;
        var rects = textRects(node);
        for (var i = 0; i < rects.length; i++) {
          if (!rects[i].width && !rects[i].height) continue;
          var right = rects[i].right;
          if (right > maxRight) maxRight = right;
        }
      }
      var media = document.body.querySelectorAll(
        'img,svg,video,table,hr,figure');
      for (var j = 0; j < media.length; j++) {
        var rect = elementRect(media[j]);
        if (!rect || (!rect.width && !rect.height)) continue;
        var mediaRight = rect.right;
        if (mediaRight > maxRight) maxRight = mediaRight;
      }
    } catch (error) {
      // 取不到时由其它测量方式兜底。
    }
    return maxRight;
  }

  function renderProbe() {
    var style = window.getComputedStyle(document.body);
    var first = document.body.firstElementChild;
    var image = document.images.length ? document.images[0] : null;
    var imageInfo = 'none';
    if (image) {
      var rect = image.getBoundingClientRect();
      imageInfo = image.naturalWidth + 'x' + image.naturalHeight +
        '→' + Math.round(rect.width) + 'x' + Math.round(rect.height);
    }
    return 'vis=' + style.visibility +
      ' display=' + style.display +
      ' children=' + document.body.children.length +
      ' first=' + (first ? first.tagName : '') +
      ' img=' + imageInfo;
  }

  function applyTransform(animate, duration) {
    duration = duration || 200;
    animate = animate && turnEffect === 'slide';
    if (animate) window.gtReaderPerf?.motion('original.slide');
    var body = document.body;
    if (!body) return;
    body.style.setProperty('transition', animate
      ? 'transform ' + duration + 'ms cubic-bezier(0.215, 0.61, 0.355, 1)'
      : 'none');
    body.style.setProperty(
      'transform', 'translateX(' + (-state.page * state.width) + 'px)');
    window.__gtInformation.move(state, 0, animate, duration);
    if (internal.highlight) internal.highlight.move(0, animate, duration);
    if (window.__gtTts) window.__gtTts.paint();
  }

  function pageAtFraction(fraction) {
    var page = Math.max(0, Math.min(
      state.pages - 1, Math.floor(fraction * state.pages + 1e-7)));
    if (window.__gtTraceBookmark) internal.post('bookmarkTrace', {
      stage: 'fraction-page', fraction: fraction, product: fraction * state.pages,
      page: page, previousPage: state.page, pages: state.pages,
      width: state.width, columnWidth: state.columnWidth,
      contentWidth: state.contentWidth, scrollWidth: state.scrollWidth,
      ms: performance.now()
    });
    return page;
  }

  function clearRelocate() {
    clearTimeout(relocateTimer);
  }

  function setPage(page, animate, reportPosition, duration) {
    internal.recovery('setPageBefore');
    duration = duration || 200;
    // 无动画没有 CSS 过渡，立即提交位置，不能仍等平移的 220ms 定时器。
    animate = animate !== false && turnEffect === 'slide';
    state.page = Math.max(0, Math.min(page, state.pages - 1));
    internal.recovery('setPageAfter');
    applyTransform(animate, duration);
    if (!animate) {
      clearRelocate();
      if (reportPosition !== false) internal.dom.reportRelocate();
      return;
    }
    internal.post('page', { page: state.page, pages: state.indexComplete ? state.pages : null,
      knownPages: state.pages, indexComplete: state.indexComplete });
    clearRelocate();
    relocateTimer = setTimeout(internal.dom.reportRelocate, duration + 20);
  }

  function measure() {
    if (internal.index) internal.index.cancel();
    state.indexComplete = true;
    var body = document.body;
    if (!body || !state.width) return;
    invalidate();
    if (window.__gtInformation.invalidateBookmarks) window.__gtInformation.invalidateBookmarks();
    state.scrollWidth = body.scrollWidth;
    state.contentWidth = Math.max(
      body.scrollWidth, contentWidth(), textMaxRight());
    var pages = Math.max(1, Math.round(state.contentWidth / state.width));
    while (pages < 500 && probePage(pages)) pages++;
    while (pages > 1 && !probePage(pages - 1)) pages--;
    state.pages = pages;
    if (state.page > state.pages - 1) state.page = state.pages - 1;
    if (state.page < 0) state.page = 0;
    applyTransform(false);
  }

  function relayout(preservePosition, changeGeometry, savedAnchor, savedProgress) {
    internal.recovery('relayoutBefore');
    var anchor = savedProgress === undefined
      ? (preservePosition ? internal.dom.captureAnchor() : null)
      : savedAnchor;
    if (changeGeometry) changeGeometry();
    measure();
    var restored = false;
    if (anchor) {
      var x = internal.dom.anchorOffsetX(anchor);
        if (x !== null && x >= 0) {
        state.page = Math.max(
          0, Math.min(Math.floor(x / state.width), state.pages - 1));
        restored = true;
      }
    }
      if (!restored && typeof savedProgress === 'number') {
      state.page = pageAtFraction(savedProgress);
    }
    applyTransform(false);
    // 字号、主题、页边距、图片就绪都会走到这里：文字位置变了，高亮要重新量一遍
    internal.recovery('relayoutAfter');
    if (internal.highlight) internal.highlight.render();
    internal.dom.reportRelocate();
  }

  function setTurnEffect(value) {
    turnEffect = value || 'slide';
    updateTransformHint();
  }

  internal.layout = {
    textRects: textRects, textRangeRects: textRangeRects,
    elementRect: elementRect,
    seedIndex: function (width, occupied) {
      geometryValues.set('contentWidth', width);
      geometryValues.set('textMaxRight', width);
      occupied.forEach(function (page) { pageProbes.set(page, true); });
      pageProbes.set(state.pages, false);
    },
    applyTransform: applyTransform,
    clearRelocate: clearRelocate,
    columnStep: columnStep,
    contentWidth: contentWidth,
    hasContentAt: hasContentAt,
    hasPage: hasPage,
    invalidate: invalidate,
    geometryVersion: checkGeometry,
    measure: measure,
    pageAtFraction: pageAtFraction,
    relayout: relayout,
    renderProbe: renderProbe,
    setPage: setPage,
    setTurnEffect: setTurnEffect,
    setupColumns: setupColumns,
    textMaxRight: textMaxRight,
    toContentX: toContentX
  };
})();
