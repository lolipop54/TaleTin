/* WebView 宿主页内部的 DOM 查询、锚点与落位能力。 */
(function () {
  'use strict';
  var internal = window.__gtHost = window.__gtHost || {};
  var state = internal.state;
  if (state.indexComplete === undefined) state.indexComplete = true;
  var pageAnchors = new Map(), anchorVersion = -1;

  function findFirstBlock(page) {
    var startX = page * state.width;
    var endX = startX + state.width;
    var blocks = document.body.querySelectorAll(
      'p,h1,h2,h3,h4,h5,h6,li,div');
    for (var i = 0; i < blocks.length; i++) {
      var rect = blocks[i].getBoundingClientRect();
      if (!rect || (!rect.width && !rect.height)) continue;
      var left = internal.layout.toContentX(rect.left);
      if (left + rect.width <= startX + 1) continue;
      if (left >= endX) continue;
      return blocks[i];
    }
    return null;
  }

  function firstVisibleTextAnchor(page) {
    if (!internal.layout.geometryVersion) return measureFirstVisibleTextAnchor(page);
    var version = internal.layout.geometryVersion();
    if (anchorVersion !== version) { pageAnchors.clear(); anchorVersion = version; }
    if (!pageAnchors.has(page)) {
      pageAnchors.set(page, measureFirstVisibleTextAnchor(page));
      if (pageAnchors.size > 64) pageAnchors.delete(pageAnchors.keys().next().value);
    }
    return pageAnchors.get(page);
  }

  function measureFirstVisibleTextAnchor(page) {
    var block = findFirstBlock(page);
    if (!block) return null;
    var walker = document.createTreeWalker(
      block, NodeFilter.SHOW_TEXT, null);
    var range = document.createRange(), node;
    var start = page * state.width, end = start + state.width;
    while ((node = walker.nextNode())) {
      if (!node.nodeValue.trim()) continue;
      range.selectNodeContents(node);
      var visible = Array.from(range.getClientRects()).some(function (rect) {
        return rect.height > 0 &&
          internal.layout.toContentX(rect.right) > start + 1 &&
          internal.layout.toContentX(rect.left) < end;
      });
      if (!visible) continue;
      var low = 0, high = node.nodeValue.length;
      while (low < high) {
        var mid = (low + high) >> 1;
        range.setStart(node, mid);
        range.setEnd(node, mid + 1);
        if (internal.layout.toContentX(
          range.getBoundingClientRect().left) < start - 1) low = mid + 1;
        else high = mid;
      }
      if (low < node.nodeValue.length) {
        return { node: node, offset: low, block: block };
      }
    }
    return null;
  }

  function captureAnchor() {
    // 重排和保存进度使用同一个真实页首点。长章只建了局部索引时，旧的
    // 容器遍历可能找不到文字；不能随后按局部页数比例跳到全章尾部。
    if (window.__gtContentTarget && internal.selection) {
      var point = internal.selection.scanPageAnchor();
      if (point && pageOfPoint(point) === state.page) {
        return {node: nodeOfPoint(point), offset: point.offset || 0,
          element: point.element === true};
      }
    }
    try {
      var visible = firstVisibleTextAnchor(state.page);
      if (visible) return visible;
    } catch (error) {
      // 使用坐标定位兜底。
    }
    try {
      var range = document.caretRangeFromPoint(1, 1);
      if (range && range.startContainer) {
        return { node: range.startContainer, offset: range.startOffset };
      }
    } catch (error) {
      // 取不到锚点时由比例恢复。
    }
    return null;
  }

  function anchorOffsetX(anchor) {
    if (!anchor) return null;
    try {
      var node = anchor.node;
      if (anchor.element) {
        var box = node.getBoundingClientRect();
        return internal.layout.toContentX(box.left);
      }
      var max = node.nodeType === 3
        ? node.nodeValue.length
        : (node.childNodes ? node.childNodes.length : 0);
      var range = document.createRange();
      var offset = Math.max(0, Math.min(anchor.offset, max));
      range.setStart(node, offset);
      // 字符范围比折叠光标可靠，跨栏或行首的折叠范围可能返回空矩形。
      if (node.nodeType === 3 && offset < max) range.setEnd(node, offset + 1);
      else range.collapse(true);
      var rect = range.getBoundingClientRect();
      if (rect && (rect.width || rect.height)) {
        return internal.layout.toContentX(rect.left);
      }
    } catch (error) {
      // 节点失效时由比例恢复。
    }
    return null;
  }

  function firstTextOnPage(page) {
    try {
      var anchor = firstVisibleTextAnchor(page);
      if (anchor) {
        var range = document.createRange();
        range.setStart(anchor.node, anchor.offset);
        range.setEndAfter(anchor.block);
        return range.toString().replace(/\s+/g, ' ').trim().slice(0, 60);
      }
    } catch (error) {
      // 图片页由比例兜底。
    }
    return '';
  }

  // 空白判定：半角/全角空格、换行、制表都算（段首缩进在书里常写成全角空格）
  function isSpace(node, offset) {
    if (offset < 0 || offset >= node.length) return false;
    return /\s/.test(node.nodeValue.charAt(offset));
  }

  // 选区两端跳过空白：段首缩进与段尾的换行、行末空格都不该被高亮，
  // 否则看起来像多画了一块。只裁两端，范围中间的空白保持原样。
  function trimWhitespace(start, startOffset, end, endOffset) {
    var from = Math.max(0, Math.min(startOffset, start.length));
    var to = Math.max(0, Math.min(endOffset, end.length));
    while (from < start.length && isSpace(start, from)) from++;
    while (to > 0 && isSpace(end, to - 1)) to--;
    return { startOffset: from, endOffset: to };
  }

  function compactText(value) {
    return (value || '').replace(/\s+/g, '');
  }

  function findHeadingOfText(text) {
    var needle = compactText(text);
    if (!needle) return null;
    try {
      var headings = document.body.querySelectorAll('h1,h2,h3,h4,h5,h6');
      for (var i = 0; i < headings.length; i++) {
        var value = compactText(headings[i].textContent);
        if (!value) continue;
        if (value.indexOf(needle) === 0 || needle.indexOf(value) === 0) {
          return headings[i];
        }
      }
    } catch (error) {
      // 找不到标题时由 Dart 侧使用其它落位方式。
    }
    return null;
  }

  function textOfElement(element) {
    try {
      var text = (element.textContent || '').replace(/\s+/g, ' ').trim();
      if (text) return text.slice(0, 60);
    } catch (error) {
      // 取不到时按页首上报。
    }
    return '';
  }

  function landOnElement(element) {
    if (!element) return false;
    var rect = null;
    try {
      rect = element.getBoundingClientRect();
    } catch (error) {
      // 老 WebView 取不到时返回 false。
    }
    if (!rect) return false;
    var contentX = internal.layout.toContentX(rect.left);
    var page = Math.max(0, Math.floor((contentX + 1) / state.width));
    if (!state.indexComplete) state.pages = Math.max(state.pages, page + 1);
    internal.layout.setPage(page, false, false);
    var span = state.pages * state.width;
    reportRelocate(element, span > 0 ? contentX / span : null);
    return true;
  }

  function reportRelocate(anchorElement, anchorFraction) {
    var perfStart = window.gtReaderPerf ? performance.now() : 0;
    var traceStart = window.__gtTraceTurn ? performance.now() : null;
    var point = window.__gtContentTarget && internal.selection
      ? internal.selection.scanPageAnchor() : null;
    if (window.__gtContentTarget && internal.content && internal.content.fraction(point) === null) {
      point = internal.index.pointForPage(state.page, true);
    }
    if (window.__gtContentTarget && !point && !state.indexComplete) {
      var waitingPage = state.page;
      internal.index.ensure(Infinity).then(function () {
        if (state.page === waitingPage) reportRelocate(anchorElement, anchorFraction);
      });
      return;
    }
    var pointNode = point && nodeOfPoint(point);
    var firstText = pointNode && pointNode.nodeType === 3
      ? pointNode.nodeValue.slice(point.offset, point.offset + 60).replace(/\s+/g, ' ').trim()
      : anchorElement
      ? textOfElement(anchorElement)
      : (window.__gtContentTarget ? '' : firstTextOnPage(state.page));
    var fraction = anchorFraction;
    var contentFraction = point && internal.content ? internal.content.fraction(point) : null;
    if (fraction === undefined || fraction === null || !isFinite(fraction)) {
      fraction = state.pages <= 1 ? 0 : state.page / state.pages;
    }
    internal.post('relocate', {
      page: state.page,
      pages: state.indexComplete ? state.pages : null,
      knownPages: state.pages,
      indexComplete: state.indexComplete,
      width: state.width,
      step: window.__gtContentTarget ? state.width : internal.layout.columnStep(),
      columnWidth: state.columnWidth,
      contentWidth: state.contentWidth,
      scrollWidth: state.scrollWidth,
      fraction: Math.max(0, Math.min(1, fraction)),
      contentFraction: contentFraction,
      firstText: firstText,
      point: point
    });
    window.gtReaderPerf?.step('original.page.positionQuery', perfStart, {page: state.page});
    if (traceStart !== null) internal.post('turnTrace', {
      stage: 'page-position-query', ms: performance.now(),
      elapsedMs: performance.now() - traceStart,
      page: state.page, pages: state.pages, anchored: !!anchorElement
    });
  }

  function metrics() {
    var root = document.documentElement;
    return {
      title: document.title || '',
      width: root ? root.clientWidth : 0,
      height: root ? root.clientHeight : 0,
      images: document.images ? document.images.length : 0,
      paragraphs: document.querySelectorAll('p').length,
      headings: document.querySelectorAll('h1,h2,h3,h4,h5,h6').length,
      bodyChildren: document.body ? document.body.children.length : 0,
      scrollHeight: root ? root.scrollHeight : 0
    };
  }

  function goToText(text, fraction) {
    var needle = compactText(text).slice(0, 24);
    if (needle.length < 6) return false;
    var walker = document.createTreeWalker(
      document.body, NodeFilter.SHOW_TEXT, null);
    var parts = [], nodes = [], node;
    while ((node = walker.nextNode())) {
      var value = compactText(node.nodeValue);
      if (!value || !node.parentElement.getClientRects().length) continue;
      parts.push(value);
      nodes.push(node);
    }
    var content = parts.join(''), hit = content.indexOf(needle), best = -1;
    while (hit >= 0) {
      if (best < 0 || Math.abs(hit / content.length - fraction) <
          Math.abs(best / content.length - fraction)) best = hit;
      hit = content.indexOf(needle, hit + 1);
    }
    if (best < 0) return false;
    for (var i = 0; i < nodes.length; i++) {
      if (best >= parts[i].length) {
        best -= parts[i].length;
        continue;
      }
      var raw = nodes[i].nodeValue, offset = 0;
      while (offset < raw.length && (best > 0 || /\s/.test(raw[offset]))) {
        if (!/\s/.test(raw[offset])) best--;
        offset++;
      }
      var range = document.createRange();
      range.setStart(nodes[i], offset);
      range.setEnd(nodes[i], offset + 1);
      var x = internal.layout.toContentX(range.getBoundingClientRect().left);
      internal.layout.setPage(Math.floor((x + 1) / state.width), false);
      return true;
    }
    return false;
  }

  function imageAt(x, y) {
    var element = document.elementFromPoint(x, y);
    if (!element) return null;
    if (element.tagName.toLowerCase() === 'img') {
      return element.currentSrc || element.src;
    }
    if (element.tagName.toLowerCase() === 'image') {
      var href = element.getAttribute('href') ||
        element.getAttribute('xlink:href');
      return href ? new URL(href, document.baseURI).href : null;
    }
    return null;
  }

  function linkAt(x, y) {
    try {
      var element = document.elementFromPoint(x, y);
      while (element && element.tagName) {
        if (element.tagName === 'A') {
          var href = element.getAttribute('href');
          if (href) return href;
        }
        element = element.parentElement;
      }
    } catch (error) {
      // 取不到时按普通点击处理。
    }
    return null;
  }

  function goToDomPoint(point) {
    var page = pageOfPoint(point);
    if (page === null) return false;
    // 精确点证明这一页存在，不受尚未完成的总页数索引夹限。
    if (!state.indexComplete) state.pages = Math.max(state.pages, page + 1);
    internal.layout.setPage(page, false);
    return true;
  }

  function nodeOfPoint(point) {
    var node = document.body;
    for (var i = 0; i < point.path.length; i++) {
      node = node && node.childNodes[point.path[i]];
    }
    return node;
  }

  function pageOfPoint(point) {
    var node = nodeOfPoint(point);
    if (point.element === true) {
      if (!node || node.nodeType !== 1) return null;
      var box = node.getBoundingClientRect();
      if (!box.width && !box.height) return null;
      return Math.max(0, Math.floor((internal.layout.toContentX(box.left) + 1) / state.width));
    }
    if (!node || node.nodeType !== 3 || point.offset > node.length) {
      return null;
    }
    var offset = Math.min(point.offset, Math.max(0, node.length - 1));
    var range = document.createRange();
    range.setStart(node, offset);
    range.setEnd(node, Math.min(node.length, offset + 1));
    var rects = range.getClientRects();
    if (!rects.length) return null;
    var x = internal.layout.toContentX(rects[0].left);
    return Math.max(0, Math.floor((x + 1) / state.width));
  }

  function goToAnchor(id) {
    var element = null;
    try {
      element = document.getElementById(id);
      if (!element) element = document.getElementsByName(id)[0];
      // Dart URI 和旧目录数据会保留百分号编码，DOM 的中文 id 则是原文。
      // 先匹配原样 id，避免把正文中本来就含 % 的合法锚点解错。
      if (!element && id.indexOf('%') >= 0) {
        var decoded = decodeURIComponent(id);
        element = document.getElementById(decoded) ||
          document.getElementsByName(decoded)[0];
      }
    } catch (error) {
      // 老 WebView 取不到时返回 false。
    }
    return landOnElement(element);
  }

  internal.dom = {
    pageOfPoint: pageOfPoint,
    nodeOfPoint: nodeOfPoint,
    anchorOffsetX: anchorOffsetX,
    captureAnchor: captureAnchor,
    findHeadingOfText: findHeadingOfText,
    goToAnchor: goToAnchor,
    goToDomPoint: goToDomPoint,
    goToText: goToText,
    imageAt: imageAt,
    landOnElement: landOnElement,
    linkAt: linkAt,
    metrics: metrics,
    reportRelocate: reportRelocate,
    trimWhitespace: trimWhitespace
  };
})();
