/* 原书 DOM 选区：视口点 → DOM 文本点，DOM 范围 → 视口矩形（实现计划 S4）。
 *
 * 位置口径与听书高亮完全一致：节点路径相对 `document.body`（框架脚本只插在
 * head 里，body 子节点序不受影响），偏移是文本节点内的 UTF-16 偏移。Dart 侧用
 * 净化正文对照表把这个点换算成 Locator，重复句、内联标签、空白折叠因此走同一套
 * 规则，不靠搜相同文字猜位置。
 *
 * 职责边界：只做几何查询。不改分页、不动正文结构、不切临时页、不上报位置，
 * 「选中的是哪段文字、要不要保存」都由 Dart 决定。
 */
(function () {
  'use strict';
  var internal = window.__gtHost = window.__gtHost || {};
  var state = internal.state;

  // 视口宽（CSS 像素），Dart 侧按它把矩形换算回阅读页坐标
  function viewportWidth() {
    var root = document.documentElement;
    return root ? root.clientWidth : 0;
  }

  // 双页同屏仍有两栏：先读完左栏再读右栏，不能先按整屏页号再按行高排。
  // 页号继续按整屏推进，仅矩形的阅读顺序使用半屏栏宽。
  function compareBoxes(a, b) {
    var spread = window.__gtInformation && window.__gtInformation.spread();
    var step = state.width / (spread ? 2 : 1);
    var shift = state.page * state.width;
    var columnA = Math.floor((a.left + shift + 1) / step);
    var columnB = Math.floor((b.left + shift + 1) / step);
    return columnA - columnB || a.top - b.top || a.left - b.left;
  }

  // 节点在 body 内的子节点序号路径；不在正文里（如框架覆盖层）返回 null
  function pathOf(node) {
    var path = [];
    while (node && node !== document.body) {
      var parent = node.parentNode;
      if (!parent) return null;
      path.push(Array.prototype.indexOf.call(parent.childNodes, node));
      node = parent;
    }
    return node === document.body ? path.reverse() : null;
  }

  function nodeAt(path) {
    var node = document.body;
    for (var i = 0; i < path.length; i++) {
      node = node && node.childNodes[path[i]];
    }
    return node;
  }

  function clampOffset(node, offset) {
    return Math.max(0, Math.min(offset, node.length));
  }

  // 视口坐标的一点 → 它所在文字的 DOM 点。
  //
  // 点在图片、空白或元素边界上时**没有文字可锚**（caretRangeFromPoint 会给出
  // 元素容器或最近的文字），这两种情况都返回 null，由 Dart 按「没选中」处理：
  // 不能把最近的一段文字当用户点中的那一段。
  //
  // 点还必须落在正文流的纵向范围里：手柄推到页尾下方（手指已经出了正文区）时，
  // `caretRangeFromPoint` 会吸到**别的列**上的文字，选区一下跳到前面好几页，
  // 手柄全都不在本页、看起来就是「拖不动了」（真机反馈）。这种位置交给页沿
  // 计时去翻页，不在这里改选区。
  function pointAt(x, y, character) {
    var body = contentBox();
    if (y < body.top || y > body.top + body.height) return null;
    if (x < 0 || x > viewportWidth()) return null;
    var range = null;
    try {
      if (document.caretRangeFromPoint) {
        range = document.caretRangeFromPoint(x, y);
      } else if (document.caretPositionFromPoint) {
        var position = document.caretPositionFromPoint(x, y);
        if (position) {
          range = document.createRange();
          range.setStart(position.offsetNode, position.offset);
        }
      }
    } catch (error) {
      return null;
    }
    if (!range) return null;
    var node = range.startContainer;
    if (!node || node.nodeType !== 3 || !node.nodeValue) return null;
    var path = pathOf(node);
    if (!path) return null;
    var offset = clampOffset(node, range.startOffset);
    if (character) {
      // 长按要命中字本身；浏览器返回的是字两侧的插入点，句号附近会串句。
      var hit = null;
      for (var i = Math.max(0, offset - 1); i <= offset + 1 && i < node.length; i++) {
        var glyph = charRectOf(node, i);
        if (glyph && x >= glyph.left && x < glyph.right &&
            y >= glyph.top && y < glyph.bottom) { hit = i; break; }
      }
      if (hit === null) return null;
      offset = hit;
    }
    // 光标位上的那个字必须真的落在本页这一栏里：页尾最后一行下方那段空档里，
    // caretRangeFromPoint 会吸到**相邻栏**上的文字（横坐标跑到视口外），
    // 选区一下跳到别的页，手柄全都不在本页、看着就是「拖不动」（真机反馈）。
    // 用单字矩形核对（它一定不是零尺寸，比光标的零宽矩形可靠）
    var at = charRectOf(node, offset) || charRectOf(node, offset - 1);
    if (at && (at.right <= 1 || at.left >= viewportWidth() - 1)) {
      // 页末光标可能位于最后一个字之后，此时 offset 指向下一栏的首字。
      // 前一个字仍在手指附近、本页同一行时，这个插入点有效，不能误当邻栏丢掉。
      var previous = charRectOf(node, offset - 1);
      if (!previous || previous.right <= 1 || previous.left >= viewportWidth() - 1 ||
          y < previous.top - previous.height / 2 ||
          y > previous.bottom + previous.height / 2) return null;
    }
    return {
      path: path,
      offset: offset,
      width: viewportWidth()
    };
  }

  // 两个 DOM 文本点之间的范围；节点取不到或不是文字时返回 null
  function rangeOf(from, to) {
    var start = nodeAt(from.path), end = nodeAt(to.path);
    if (!start || !end) return null;
    if (start.nodeType !== 3 || end.nodeType !== 3) return null;
    // 两端跳过空白：段首缩进与段尾空格不算选中
    var trimmed = internal.dom.trimWhitespace(
      start, clampOffset(start, from.offset),
      end, clampOffset(end, to.offset));
    var range = document.createRange();
    range.setStart(start, trimmed.startOffset);
    range.setEnd(end, trimmed.endOffset);
    return range;
  }

  // 正文区在视口里的范围（不含上下信息行）。
  //
  // body 是多栏容器，getBoundingClientRect 的横向范围是全部列，只有纵向可用：
  // 页首/页末落在哪儿、手指有没有推出正文区，都按这个范围判断。
  function contentBox() {
    if (!document.body) return {top: 0, height: 0};
    var rect = document.body.getBoundingClientRect();
    return { top: rect.top, height: rect.height };
  }

  // 当前页靠近页首/页末的文字位置（翻页扩选后端点要落在新页这一侧）。
  //
  // 做法：从正文区左上角（页首）或右下角（页末）往里扫，取第一个**真的落在本页**
  // 的位置——`pointAt` 已经核对了那一点的光标字确实压在本页这一栏里。
  //
  // 不再用「按文字节点找第一个压在本页的节点，再在节点上二分」那套：段落从上一页
  // 延续过来时节点首字在上一页，行尾的零宽矩形又会骗过单字判定，取出来的位置可能
  // 落在前面几页上（真机反馈：翻页扩选后拖动的那一端落到上一页，手柄全不在本页）。
  function pageEdgePoint(atEnd) {
    var box = contentBox();
    var width = viewportWidth();
    var margin = Math.max(2, state.margin + 2);
    var x = atEnd ? width - margin : margin;
    var step = 10;
    for (var i = 0; i * step < box.height; i++) {
      var y = atEnd
        ? box.top + box.height - 2 - i * step
        : box.top + 2 + i * step;
      var point = pointAt(x, y);
      if (!point) continue;
      if (!atEnd) return point;
      // 往回翻时取的是本页最后一个字：光标常吸在行尾「之后」，退一格才是那个字
      var node = nodeAt(point.path);
      if (node && node.nodeType === 3 && point.offset > 0) {
        var rect = charRectOf(node, point.offset - 1);
        if (rect && rect.right > 1 && rect.left < width - 1) {
          return { path: point.path, offset: point.offset - 1, width: width };
        }
      }
      return point;
    }
    return null;
  }

  /// 一段文字的矩形里落在当前页上的那一个；没有就返回 null
  function onPageRect(node) {
    var width = viewportWidth();
    var rects = charRects(node);
    for (var i = 0; i < rects.length; i++) {
      var rect = rects[i];
      if (rect.width <= 0 && rect.height <= 0) continue;
      if (rect.right > 1 && rect.left < width - 1) return rect;
    }
    return null;
  }

  /// 本页第一段（atEnd=false）/ 最后一段（true）文字所在的节点。
  ///
  /// 靠矩形是否落在本页判定，不用 caretRangeFromPoint 去猜页首：页首常留空档
  /// （段落间距、上一段的收尾），最近的行可能属于相邻页，猜出来的位置会把
  /// 选区一下子挪到别的页上去（真机上出现过）。
  function pageEdgeTextNode(atEnd) {
    var nodes = textNodes();
    var order = atEnd ? nodes.slice().reverse() : nodes;
    for (var i = 0; i < order.length; i++) {
      if (onPageRect(order[i])) return order[i];
    }
    return null;
  }

  function textNodes() {
    var nodes = [];
    var walker = document.createTreeWalker(
      document.body, NodeFilter.SHOW_TEXT, null);
    var node;
    while ((node = walker.nextNode())) {
      if (node.nodeValue && node.nodeValue.trim()) nodes.push(node);
    }
    return nodes;
  }

  function charRects(node) {
    var range = document.createRange();
    range.selectNodeContents(node);
    return range.getClientRects();
  }

  function charRectOf(node, offset) {
    var length = node.nodeValue.length;
    if (offset < 0 || offset >= length) return null;
    var range = document.createRange();
    range.setStart(node, offset);
    range.setEnd(node, offset + 1);
    var rects = range.getClientRects();
    return rects.length ? rects[0] : null;
  }

  // 交叉后，原来的段尾可成为选区开头，原来的段首可成为选区结尾。
  // 这两个插入点没有对应的字；沿选区内侧找实际首末字，不能把两端一起丢掉。
  function rangeEdgeRect(range, atEnd) {
    var node = atEnd ? range.endContainer : range.startContainer;
    var stop = atEnd ? range.startContainer : range.endContainer;
    var offset = atEnd ? range.endOffset - 1 : range.startOffset;
    var limit = atEnd ? range.startOffset : range.endOffset;
    var step = atEnd ? -1 : 1;
    while (node) {
      if (node.nodeType === 3) {
        while (offset >= 0 && offset < node.length &&
            (node !== stop || (atEnd ? offset >= limit : offset < limit))) {
          if (!/\s/.test(node.nodeValue[offset])) {
            var rect = charRectOf(node, offset);
            if (rect && rect.height > 0) return rect;
          }
          offset += step;
        }
      }
      // 到另一端就停止；不拿选区外的下一段文字补位置。
      if (node === stop) return null;
      while (node !== document.body && !(atEnd ? node.previousSibling : node.nextSibling)) {
        node = node.parentNode;
      }
      if (node === document.body) return null;
      node = atEnd ? node.previousSibling : node.nextSibling;
      while (node.nodeType !== 3 && (atEnd ? node.lastChild : node.firstChild)) {
        node = atEnd ? node.lastChild : node.firstChild;
      }
      offset = atEnd && node.nodeType === 3 ? node.length - 1 : 0;
    }
    return null;
  }

  // 段尾到下一段段首可能没有字，但浏览器会给出两侧的零宽光标。
  // 优先保留显示页上的那个，两端经过重合位置时仍可继续拖动。
  function rangeCaretRect(range) {
    var boxes = range.getClientRects(), first = null;
    for (var i = 0; i < boxes.length; i++) {
      var rect = boxes[i];
      if (rect.width !== 0 || rect.height <= 0) continue;
      if (!first) first = rect;
      if (rect.left >= 0 && rect.left < viewportWidth()) return rect;
    }
    return first;
  }

  // 底色会按高度切成横带；混合字体时，最后一条细带可能只属于行中的英文。
  // 手柄必须直接取范围首字/末字，不能拿合并底色的 first/last 当端点。
  function rangeEndpoints(from, to) {
    var range = rangeOf(from, to);
    if (!range) return null;
    if (range.startContainer === range.endContainer &&
        range.startOffset === range.endOffset) {
      var caret = rangeCaretRect(range);
      return caret ? {leading: caret, trailing: caret} : null;
    }
    var endpoints = {
      leading: rangeEdgeRect(range, false),
      trailing: rangeEdgeRect(range, true)
    };
    if (!endpoints.leading && !endpoints.trailing) {
      var boundary = rangeCaretRect(range);
      if (boundary) return {leading: boundary, trailing: boundary};
    }
    return endpoints;
  }

  // 本页文字的纵向范围（首行上沿、末行下沿）。
  //
  // 正文区底部常留一段空档（段落结束、图片在下方），页首/页末判定要按**文字**
  // 算：不然手柄停在最后一行也够不到「页尾那一带」，往下推再久也不翻页。
  function pageTextBounds() {
    var head = pageEdgeTextNode(false);
    var headRect = head ? onPageRect(head) : null;
    var tail = pageEdgeTextNode(true);
    var tailRect = tail ? onPageRect(tail) : null;
    return {
      top: headRect ? headRect.top : 0,
      bottom: tailRect ? tailRect.bottom : 0
    };
  }

  // 范围矩形（视口坐标）：每个被选中的块，它的**第一行**左沿夹到第一个可见字的左沿。
  //
  // 原书里段落首行常用 CSS `text-indent`（不是空白字符），浏览器给的范围矩形从
  // **行盒起点**算起；段首还可能是正文里写的全角空格。以前只夹「范围起点」那一个
  // 字：多段选取时后面每一段的首行仍带着缩进，长按一段时所有行的左沿还被一起夹到
  // 起点字的缩进上，看起来就是「段前空格也高亮了」「所有行都缩进了」（真机反馈）。
  // 缩进只作用在块的第一个字，所以这里按**块**算：每个块的第一个可见字从哪里开始，
  // 它的第一行就从哪里开始画；其余行的行盒左沿本来就是正文左沿，不动。
  function rangeBoxes(from, to, merge) {
    var range = rangeOf(from, to);
    if (!range) return null;
    var boxes = [];
    Array.prototype.forEach.call(range.getClientRects(), function (rect) {
      if (rect.width <= 0 || rect.height <= 0) return;
      boxes.push({
        left: rect.left,
        top: rect.top,
        right: rect.right,
        bottom: rect.bottom
      });
    });
    trimBlockStarts(range, boxes);
    var result = [];
    for (var i = 0; i < boxes.length; i++) {
      if (boxes[i].right - boxes[i].left > 0) result.push(boxes[i]);
    }
    // merge 为假时给调用方留原始矩形（要按矩形找本页首末文字，合并过的横带
    // 可能只剩一条细边，拿它取字会取到下一段去）
    return merge === false ? result : unionBoxes(result);
  }

  /// 把一组矩形合成**互不重叠**的一组矩形。
  ///
  /// 浏览器给的范围矩形不保证互不重叠：一块正文被整个选中时，它除了逐行矩形，
  /// 还会多给一个覆盖整块的矩形。同一个方块画两遍，底色就比别处更深——真机上
  /// 表现为「多段高亮合并后，中间一段颜色变重」（用户反馈，误以为高亮了两次）。
  /// 这里按 y 切成横带，每条带里把 x 区间并起来，保证每个像素只画一次。
  function unionBoxes(boxes) {
    if (boxes.length <= 1) return boxes;
    var cuts = [];
    for (var i = 0; i < boxes.length; i++) {
      cuts.push(boxes[i].top, boxes[i].bottom);
    }
    cuts.sort(function (a, b) { return a - b; });
    var result = [];
    for (var k = 0; k + 1 < cuts.length; k++) {
      var top = cuts[k], bottom = cuts[k + 1];
      if (bottom - top <= 0.5) continue;
      var spans = [];
      for (var j = 0; j < boxes.length; j++) {
        var box = boxes[j];
        if (box.top > top + 0.5 || box.bottom < bottom - 0.5) continue;
        spans.push([box.left, box.right]);
      }
      spans.sort(function (a, b) { return a[0] - b[0]; });
      var merged = [];
      for (var s = 0; s < spans.length; s++) {
        var last = merged.length ? merged[merged.length - 1] : null;
        if (last && spans[s][0] <= last[1] + 0.5) {
          if (spans[s][1] > last[1]) last[1] = spans[s][1];
        } else {
          merged.push([spans[s][0], spans[s][1]]);
        }
      }
      for (var m = 0; m < merged.length; m++) {
        if (merged[m][1] - merged[m][0] <= 0) continue;
        result.push({
          left: merged[m][0],
          top: top,
          right: merged[m][1],
          bottom: bottom
        });
      }
    }
    return result;
  }

  // 块级元素：段首缩进只作用在块的第一行，行内标签（em、span）不参与，
  // 否则会把一行从中间切开。
  var BLOCK_TAGS = {
    BODY: 1, P: 1, DIV: 1, LI: 1, UL: 1, OL: 1, DL: 1, DT: 1, DD: 1,
    H1: 1, H2: 1, H3: 1, H4: 1, H5: 1, H6: 1, BLOCKQUOTE: 1, PRE: 1,
    SECTION: 1, ARTICLE: 1, ASIDE: 1, HEADER: 1, FOOTER: 1, MAIN: 1,
    FIGURE: 1, FIGCAPTION: 1, TABLE: 1, TD: 1, TH: 1, CAPTION: 1, HR: 1
  };

  // 这段范围覆盖到的块级元素：用带过滤的 TreeWalker 只走与范围相交的分支，
  // 不做整篇文档遍历。
  function coveredBlocks(range) {
    var list = [];
    if (!range.intersectsNode || !document.createTreeWalker) return list;
    var walker = document.createTreeWalker(
      document.body, NodeFilter.SHOW_ELEMENT, {
        acceptNode: function (node) {
          try {
            return range.intersectsNode(node)
              ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT;
          } catch (error) {
            // 节点已失效（文档换过）时当作不相关
            return NodeFilter.FILTER_REJECT;
          }
        }
      });
    var node;
    while ((node = walker.nextNode())) {
      if (node.tagName && BLOCK_TAGS[node.tagName.toUpperCase()]) {
        list.push(node);
      }
    }
    return list;
  }

  // 一个块里第一个可见字（跳过段首空白）的矩形；没有文字或取不到时返回 null。
  //
  // 用矩形而不是 `caretRangeFromPoint`：后者只在视口内有效，隔着几页的持久高亮
  // 量出来就会带着缩进，翻到那一页才看得到错。
  function firstGlyphRect(element) {
    var walker = document.createTreeWalker(
      element, NodeFilter.SHOW_TEXT, null);
    var node;
    while ((node = walker.nextNode())) {
      var text = node.nodeValue;
      if (!text) continue;
      var offset = 0;
      while (offset < text.length && /\s/.test(text.charAt(offset))) offset++;
      if (offset >= text.length) continue;
      return charRectOf(node, offset);
    }
    return null;
  }

  // 把每个被选中的块的第一行左沿夹到它第一个可见字的左沿
  function trimBlockStarts(range, boxes) {
    var blocks = coveredBlocks(range);
    for (var i = 0; i < blocks.length; i++) {
      var glyph = firstGlyphRect(blocks[i]);
      if (!glyph) continue;
      var x = (glyph.left + glyph.right) / 2;
      var y = (glyph.top + glyph.bottom) / 2;
      for (var j = 0; j < boxes.length; j++) {
        var box = boxes[j];
        if (x < box.left || x > box.right) continue;
        if (y < box.top || y > box.bottom) continue;
        // 第一个字本来就贴着左沿时（行中起选）不变
        if (glyph.left > box.left && glyph.left < box.right) box.left = glyph.left;
      }
    }
  }

  // 矩形里有没有压着这个字的矩形（纵向也要压在同一行上）
  function charInsideBox(rect, box) {
    return !!rect && rect.left >= box.left - 1 && rect.right <= box.right + 1 &&
      rect.bottom > box.top + 1 && rect.top < box.bottom - 1;
  }

  /// 矩形里的第一个字（[atEnd] 为 false）或最后一个字（true）的 DOM 点。
  ///
  /// `caretRangeFromPoint` 会吸到最近的插入点：问右沿时常常吸到**后一个字**
  /// （可能在下一页），问左沿时吸到前一个字。这里在吸到的位置附近核对字符矩形
  /// 有没有真的压在这个矩形里，取最靠前/最靠后的那个，端点才不会跑到别的页去。
  function charInBox(box, atEnd) {
    var point = pointAt(
      atEnd ? box.right - 1 : box.left + 1, (box.top + box.bottom) / 2);
    if (!point) return null;
    var node = nodeAt(point.path);
    if (!node || node.nodeType !== 3) return null;
    var base = clampOffset(node, point.offset);
    var best = -1;
    for (var delta = -3; delta <= 3; delta++) {
      var index = base + delta;
      if (index < 0 || index >= node.length) continue;
      if (!charInsideBox(charRectOf(node, index), box)) continue;
      if (best < 0 || (atEnd ? index > best : index < best)) best = index;
    }
    if (best < 0) return null;
    return {path: point.path, offset: best, width: viewportWidth()};
  }

  // 范围矩形，**视口坐标**（已含当前页平移）；Dart 加上阅读页原点直接绘制。
  //
  // 跨页范围返回的矩形可能落在视口外：这是留给 Dart 判断「还要翻几页」的信息，
  // 不在这里裁剪，免得把判断依据裁掉。
  // 页边界上的端点也可从相邻页抓取；只提供落点，不改变范围。
  function continuationAnchor(point, edge, before) {
    var node = nodeAt(point.path), offset = point.offset - (before ? 1 : 0);
    if (!node) return null;
    var step = before ? -1 : 1;
    // 跨内联标签/段落只沿端点方向找文字，不遍历整章。
    while (node) {
      if (node.nodeType === 3) {
        while (offset >= 0 && offset < node.nodeValue.length) {
          if (!/\s/.test(node.nodeValue[offset])) {
            var neighbor = charRectOf(node, offset);
            var shift = state.page * state.width;
            var ownX = before ? edge.left + 1 : edge.right - 1;
            var neighborX = neighbor && (before ? neighbor.right - 1 : neighbor.left + 1);
            if (neighbor && Math.floor((neighborX + shift) / state.width) ===
                Math.floor((ownX + shift) / state.width) + step) {
              return {left: before ? neighbor.right : neighbor.left,
                top: neighbor.top, bottom: neighbor.bottom};
            }
            return null;
          }
          offset += step;
        }
      }
      while (node !== document.body && !(before ? node.previousSibling : node.nextSibling)) {
        node = node.parentNode;
      }
      if (node === document.body) return null;
      node = before ? node.previousSibling : node.nextSibling;
      while (node && node.nodeType !== 3 && (before ? node.lastChild : node.firstChild)) {
        node = before ? node.lastChild : node.firstChild;
      }
      offset = before && node.nodeType === 3 ? node.nodeValue.length - 1 : 0;
    }
    return null;
  }

  function rects(from, to) {
    // 先用**原始矩形**找本页首末文字（合并成横带后可能只剩一条细边）
    var raw = rangeBoxes(from, to, false);
    if (!raw) return null;
    // 画出去的是**合并后**的矩形：同一段选区的方块互不重叠，不会叠出更深的颜色
    var boxes = unionBoxes(raw);
    var width = viewportWidth();
    var list = [];
    Array.prototype.forEach.call(boxes, function (rect) {
      // 这一段在排版的第几页（相对当前页）：0 是当前页、正数往后（诊断用）
      var page = Math.floor(
        (rect.left + state.page * state.width + 1) / state.width
      ) - state.page;
      // 是不是落在当前页上：直接看它自己的横坐标。不信页序——宿主页的页序
      // 偶尔与画面不同步，靠它判断会把本页的矩形当成别页的，手柄就不画了
      var onPage = rect.right > 1 && rect.left < width - 1;
      list.push({
        left: rect.left,
        top: rect.top,
        right: rect.right,
        bottom: rect.bottom,
        page: page,
        onPage: onPage
      });
    });
    // 两端重合时 Range 会给出零宽光标，不能把正在拖动的手柄一起撤掉。
    if (!list.length) {
      var collapsed = rangeOf(from, to);
      var caret = collapsed && rangeCaretRect(collapsed);
      if (caret) {
        list.push({left: caret.left, right: caret.left, top: caret.top,
          bottom: caret.bottom, page: Math.floor((caret.left + 1) / state.width),
          onPage: caret.left >= 0 && caret.left < width});
      }
    }
    var box = contentBox();
    var text = pageTextBounds();
    var endpoints = rangeEndpoints(from, to);
    // 底色和菜单仍按阅读顺序回传；手柄另取首末字，不能从横带顺序猜端点。
    list.sort(compareBoxes);
    raw.sort(compareBoxes);
    // 本页那一段的首末文字点：取**真的压在本页矩形里**的那个字，给 Dart 把范围
    // 夹在本页内。不能直接用 caretRangeFromPoint 的返回值：它会吸到后一个字
    // （可能在下一页），夹取就落空了，页末那一段的终点手柄也就不画了。
    var pageFrom = null, pageTo = null;
    for (var i = 0; i < raw.length; i++) {
      var box0 = raw[i];
      if (!(box0.right > 1 && box0.left < width - 1)) continue;
      if (!pageFrom) pageFrom = charInBox(box0, false);
      pageTo = charInBox(box0, true) || pageTo;
    }
    return {
      width: viewportWidth(),
      contentTop: box.top,
      contentHeight: box.height,
      textTop: text.top,
      textBottom: text.bottom,
      pageFrom: pageFrom,
      pageTo: pageTo,
      leading: endpoints && endpoints.leading ? {
        left: endpoints.leading.left, bottom: endpoints.leading.bottom,
        height: endpoints.leading.bottom - endpoints.leading.top
      } : null,
      trailing: endpoints && endpoints.trailing ? {
        left: endpoints.trailing.right, bottom: endpoints.trailing.bottom,
        height: endpoints.trailing.bottom - endpoints.trailing.top
      } : null,
      previousContinuation: endpoints && endpoints.leading
        ? continuationAnchor(from, endpoints.leading, true) : null,
      continuation: endpoints && endpoints.trailing
        ? continuationAnchor(to, endpoints.trailing) : null,
      rects: list
    };
  }

  // 扫描页首允许图片作为阅读位置；选文仍只接受文字。
  function scanPageAnchor() {
    var text = pageEdgePoint(false);
    var node = text && nodeAt(text.path);
    var glyph = node && charRectOf(node, text.offset);
    var images = document.body.querySelectorAll('img,image');
    for (var i = 0; i < images.length; i++) {
      var rect = images[i].getBoundingClientRect();
      if (rect.width <= 0 || rect.height <= 0 || rect.right <= 1 ||
          rect.left >= viewportWidth() - 1) continue;
      if (!glyph || rect.top < glyph.top) {
        return {path: pathOf(images[i]), element: true};
      }
    }
    return text;
  }

  internal.selection = {
    compareBoxes: compareBoxes,
    scanPageAnchor: scanPageAnchor,
    continuationAnchor: continuationAnchor,
    contentBox: contentBox,
    rangeBoxes: rangeBoxes,
    rangeEndpoints: rangeEndpoints,
    pageEdgePoint: pageEdgePoint,
    pageTextBounds: pageTextBounds,
    pointAt: pointAt,
    rects: rects
  };
})();
