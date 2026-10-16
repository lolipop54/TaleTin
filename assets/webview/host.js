/* 原书排版模式的框架脚本：CSS 分栏分页 + 翻页 + 位置上报。
 *
 * 原理（与 epub.js / foliate-js 同一条路线）：
 *   body 当作多栏容器，`column-width` = 一页的宽度、`column-fill: auto`，
 *   内容就会按页宽向左延伸成 N 列，每列高度等于视口高度；翻页就是横向平移。
 *   列宽、断行、断页全部交给系统 WebView 的排版引擎（Chromium），
 *   「完整还原原书 CSS」靠的正是这一点。
 *
 * 分工：这个脚本只管一章内部的渲染与分页，不跨章、不保存任何业务数据。
 * 换章、位置、进度都由 Dart 决定。位置上报只给「页序 + 比例 + 页首文字」，
 * 真正持久化的位置始终是 Dart 侧的 Locator。
 *
 * 约定：内部模块注册到 window.__gtHost，只有 host.js 创建公开的 window.__gt。 */
(function () {
  'use strict';

  var internal = window.__gtHost;
  var state = internal.state;
  var post = internal.post;
  // 诊断包才开启：以浏览器自己的时钟区分加载、排版及等待，不读取正文。
  function trace(stage) {
    if (window.__gtTraceTurn) post('turnTrace', {stage: stage, ms: performance.now()});
  }

  /* ---------- 生命周期 ---------- */

  var reported = false;

  /* 兜底：万一分栏没跑起来（脚本出错等），也必须让正文显示出来，不能白屏 */
  setTimeout(internal.style.revealContent, 2500);

  function onReady() {
    trace('window-load');
    if (reported) return;
    reported = true;
    // 这里只报告脚本就绪。设备字体由 Dart 按当前选择准备，不能把字体
    // 目录中的全部字体每章都读一遍；原书字体仍由首次排版的 ready 等待。
    post('ready', internal.dom.metrics());
    internal.style.watchImages();
  }

  window.addEventListener('error', function (event) {
    post('error', { message: String(event && event.message ? event.message : event) });
  });

  if (document.readyState === 'complete') onReady();
  else window.addEventListener('load', onReady);

  /* ---------- 对外接口（Dart 用 evaluateJavascript 调用） ---------- */

  window.__gt = {
    prepareImagePage: function (page) {
      var target = page === null || page === undefined ? state.page : page;
      var x = (target - state.page) * state.width;
      return internal.style.prepareImagesRect(x - state.width, 0,
        x + state.width * 2, innerHeight);
    },
    prepareFont: internal.style.prepareFont,
    followTtsPoint: function(point) {
      var rect = window.__gtTts.rect(point);
      if (!rect) return false;
      var page = Math.floor((internal.layout.toContentX(rect.left) + 1) /
        state.width);
      // 同页只画高亮，不重复定位和上报页首；跨页也不写视觉进度。
      if (page !== state.page) internal.layout.setPage(page, false, false);
      internal.layout.clearRelocate();
      return true;
    },
    setTtsRange: function(value) { return window.__gtTts.set(value); },
    clearTtsRange: function(version) { return window.__gtTts.clear(version); },
    ttsBoundaries: function(points) { return window.__gtTts.boundaries(points, state); },
    /* 开始分栏：Dart 在收到 ready 后下发页宽 */
    start: function (width, margin, initialFraction) {
      trace('start');
      state.width = Math.max(1, Math.round(width));
      state.margin = Math.max(0, Math.round(margin || 0));
      internal.style.markImageOnlyParagraphs();
      internal.style.markHeadingMargins();
      internal.layout.setupColumns();
      state.page = 0;
      internal.layout.applyTransform(false);
      // 等字体与图片就绪、再等两帧布局稳定，才量页数并显示正文：
      // 图片刚加载完时浏览器还没重排，此时测量会把页数算少一页
      // （实测第 6 章量成 11 页、实际 12 页），整个过程用户看不到。
      internal.style.whenContentReady(function () {
        trace('images-fonts-ready');
        requestAnimationFrame(function () {
          requestAnimationFrame(function () {
            internal.layout.measure();
            trace('measured');
            state.started = true;
            // 预载的上一章必须在首次显示前就落到末页，不能先露出章首页再定位。
            var fraction = Math.max(0, Math.min(1, initialFraction || 0));
            state.page = internal.layout.pageAtFraction(fraction);
            internal.layout.applyTransform(false);
            // 正文与高亮一起出现：等高亮下发（最多 300ms）再揭开，
            // 不然会先看到一段没有底色的正文、隔一下高亮才补上
            function showReadyPage() { internal.highlight.whenReady(function () {
              trace('highlights-ready');
              internal.highlight.render();
              internal.style.revealContent();
              // 分栏结束不等于画面可用，正文揭开并经过绘制帧后才允许预取截图。
              requestAnimationFrame(function () {
                requestAnimationFrame(function () {
                  trace('paint-frames-ready');
                  post('paginated', { pages: state.pages, width: state.width, page: state.page,
                    deferredImagePixels: !!window.__gtImageDecodeVisible,
                    bookmarkPages: window.__gtInformation.bookmarkPages ? window.__gtInformation.bookmarkPages() : {},
                    probe: internal.layout.renderProbe() });
                  internal.dom.reportRelocate();
                });
              });
            }, 300); }
            if (window.__gtImageDecodeVisible) window.__gt.prepareImagePage(state.page).then(showReadyPage);
            else showReadyPage();
            // 字体与图片解码已在首次测量前等待，不再于章首定时重复遍历整章。
            // 后续字号、视口和资源变化仍由各自的 relayout 入口重新测量。
          });
        });
      });
      return state.pages;
    },
    /* 截图预览不提交位置；Flutter 先盖住当前截图再临时切页。 */
    previewPage: function (page) {
      internal.layout.clearRelocate();
      state.page = Math.max(0, Math.min(page, state.pages - 1));
      internal.layout.applyTransform(false);
    },
    adjacentPage: function (delta) {
      var page = state.page + delta;
      if (!internal.layout.hasPage(page)) {
        return null;
      }
      state.pages = Math.max(state.pages, page + 1);
      return page;
    },
    commitPage: function (page) { internal.layout.setPage(page, false); },
    next: function (duration) {
      if (state.page >= state.pages - 1) {
        // 兜底：页数万一估保守了，先确认后面确实没字再报边界
        if (internal.layout.hasPage(state.page + 1)) {
          state.pages = state.page + 2;
          internal.layout.setPage(state.page + 1, true, undefined, duration);
          return true;
        }
        post('boundary', { edge: 'end', via: 'step' });
        return false;
      }
      internal.layout.setPage(state.page + 1, true, undefined, duration);
      return true;
    },
    prev: function (duration) {
      if (state.page <= 0) {
        post('boundary', { edge: 'start', via: 'step' });
        return false;
      }
      internal.layout.setPage(state.page - 1, true, undefined, duration);
      return true;
    },
    /* 拖动中：无动画跟手 */
    information: function (value) {
      var turnEffect = value && value.pageTurnEffect || 'slide';
      internal.layout.setTurnEffect(turnEffect);
      var changed = window.__gtInformation.configure(value);
      if (changed && state.started) {
        internal.layout.relayout(true, internal.layout.setupColumns);
      }
      window.__gtInformation.move(state, 0, false);
    },
    drag: function (dx) {
      window.gtReaderPerf?.motion('original.slide');
      var body = document.body;
      if (!body) return;
      window.__gtInformation.move(state, dx, false);
      internal.highlight.move(dx, false);
      body.style.setProperty('transition', 'none');
      body.style.setProperty('transform',
        'translateX(' + (-state.page * state.width + dx) + 'px)');
    },
    /* 松手：Dart 已按最后明确方向决定 -1/0/1，不在网页重复判距离。 */
    settle: function (pageDelta) {
      var target = state.page + pageDelta;
      if (target > state.pages - 1) {
        // 往「最后一页之后」翻：先确认真的没内容，有就补一页
        if (internal.layout.hasPage(target)) {
          state.pages = Math.max(state.pages, target + 1);
        } else {
          // via: settle —— 这条边界是「拖动松手」撞出来的，Dart 侧据此走滑动换章
          // （点击撞边界走 next/prev，报的是 via: step）
          post('boundary', { edge: 'end', via: 'settle' });
          target = state.pages - 1;
        }
      } else if (target < 0) {
        post('boundary', { edge: 'start', via: 'settle' });
        target = 0;
      }
      internal.layout.setPage(target, true);
    },
    /* 按章内比例跳转。
       比例与页序的换算必须和上报口径对称：上报的是 page/pages（最后一页不等于 1，
       见 reportRelocate），所以这里用 floor(fraction × pages) 反算。
       用 round(fraction × (pages - 1)) 的话，章末上报的 0.9（10 页的第 10 页）
       会算回第 9 页——就是「换章落点偶尔差一页」的来源。 */
    goToFraction: function (fraction) {
      var f = Math.max(0, Math.min(1, fraction));
      var page = internal.layout.pageAtFraction(f);
      internal.layout.setPage(page, false);
      return state.page;
    },
    /* 点击：一次调用里同时判断「是不是链接」和执行分区动作。
       触摸整体由 Flutter 的手势层接管（列了空集），所以点链接要在决定翻页之前
       先问一句；以前是 Flutter 先问一次、再下一次翻页命令，两次跨语言往返会拖慢
       每次点击的手感（W12 实测掉帧），合成一次就只往返一次。
       zone：prev / next / center（由 Flutter 按点击位置算好）。 */
    tap: function (x, y, zone, duration) {
      var link = window.__gt.linkAt(x, y);
      if (link) {
        post('link', { href: link });
        return 'link';
      }
      if (zone === 'prev') {
        window.__gt.prev(duration);
        return 'prev';
      }
      if (zone === 'next') {
        window.__gt.next(duration);
        return 'next';
      }
      post('centerTap');
      return 'center';
    },
    /* 使用本次排版已校正的页数判定边界；超出范围仍保留一次真实内容探测。 */
    atEdge: function () {
      var atStart = state.page <= 0;
      var atEnd = !internal.layout.hasPage(state.page + 1);
      if (atStart && atEnd) return 'both';
      if (atStart) return 'start';
      if (atEnd) return 'end';
      return '';
    },
    /* 这一点是不是书里的链接？是就返回它的 href，不是返回 null。 */
    imageAt: internal.dom.imageAt,
    linkAt: internal.dom.linkAt,
    tapTarget: function (x, y) {
      return JSON.stringify({
        markers: internal.highlight.thoughtMarkers(),
        highlight: internal.highlight.hitAt(x, y),
        image: internal.dom.imageAt(x, y),
        link: internal.dom.linkAt(x, y)
      });
    },
    openLink: function (href) { post('link', { href: href }); return true; },
    /* 原书选区（S4）：视口点 → DOM 文本点、DOM 范围 → 视口矩形。
       返回 JSON 字符串；取不到文字时返回空串，Dart 侧按「没选中」处理。 */
    selectionPointAt: function (x, y, character) {
      var point = internal.selection.pointAt(x, y, character);
      return point ? JSON.stringify(point) : '';
    },
    selectionRects: function (from, to, color, handleColor, reversed) {
      var value = internal.selection.rects(from, to);
      if (value && color) internal.highlight.setSelection({from: from, to: to, color: color, handleColor: handleColor, reversed: reversed === true});
      return value ? JSON.stringify(value) : '';
    },
    selectionHandleDrag: internal.highlight.setSelectionDrag,
    clearSelection: function () { internal.highlight.setSelection(null); },
    /* 持久高亮（笔记与高亮记录）：下发列表、清空、命中测试（S6） */
    setHighlights: function (value) { return internal.highlight.set(value); },
    clearHighlights: function (version) {
      return internal.highlight.clear(version);
    },
    highlightAt: function (x, y) { return internal.highlight.hitAt(x, y); },
    thoughtMarkers: function () { return JSON.stringify(internal.highlight.thoughtMarkers()); },
    /* 本页靠近页首/页末的文字位置：拖手柄翻页扩选后端点落在新页这一侧 */
    selectionPageEdge: function (atEnd) {
      var point = internal.selection.pageEdgePoint(atEnd === true);
      return point ? JSON.stringify(point) : '';
    },
    scanPageAnchor: function () {
      var point = internal.selection.scanPageAnchor();
      return point ? JSON.stringify(point) : '';
    },
    /* 按标题跳（目录条目名）：找不到标题返回 false，Dart 侧改用锚点或比例。 */
    goToHeading: function (text) {
      return internal.dom.landOnElement(internal.dom.findHeadingOfText(text));
    },
    /* 跳到文档里的锚点（书内链接的 #片段）：按元素的内容坐标换页。
       找不到这个 id 时返回 false，Dart 侧会把位置留在原处。 */
    goToDomPoint: internal.dom.goToDomPoint,
    goToText: internal.dom.goToText,
    goToAnchor: internal.dom.goToAnchor,
    /* 主题与字号的覆盖式更新；options: {fontSizePx, colors:{bg,text,link}} */
    applyStyle: internal.style.apply,
    /* Flutter 侧的宽度变了（旋转、状态信息开关）：重新分栏并保持位置 */
    resize: function (width, margin) {
      // 先在旧列宽下记住页首，再改变几何；否则旋转会把新排版中的旧页号当落点。
      internal.layout.relayout(true, function () {
        state.width = Math.max(1, Math.round(width));
        if (margin !== undefined && margin !== null) {
          state.margin = Math.max(0, Math.round(margin));
        }
        internal.layout.setupColumns();
      });
      return state.pages;
    },
    state: function () {
      return JSON.stringify({
        width: state.width,
        margin: state.margin,
        columnWidth: state.columnWidth,
        page: state.page,
        pages: state.pages,
        started: state.started,
        bookmarkPages: window.__gtInformation.bookmarkPages ? window.__gtInformation.bookmarkPages() : {},
        scrollWidth: document.body ? document.body.scrollWidth : 0,
        contentWidth: internal.layout.contentWidth()
      });
    },
    /* 自检：把几种页数算法摆在一起，用来定位「翻不到的那一页」。
       正常应当 byWidth 与 probed 一致、且都等于 pages。 */
    audit: function () {
      var byMeasure = Math.max(
        document.body ? document.body.scrollWidth : 0,
        internal.layout.contentWidth(),
        internal.layout.textMaxRight());
      var byWidth = Math.max(1, Math.round(byMeasure / state.width));
      var probed = 1;
      while (probed < 500 &&
          internal.layout.hasContentAt(probed * state.width)) {
        probed++;
      }
      // 渲染诊断：正文看不见时，先看这里（可见性、图片尺寸、首个子元素）
      var bodyStyle = window.getComputedStyle(document.body);
      var firstChild = document.body.firstElementChild;
      var firstChildStyle = firstChild ? window.getComputedStyle(firstChild) : null;
      var imageProbe = Array.prototype.slice
        .call(document.images).slice(0, 3).map(function (image) {
          var rect = image.getBoundingClientRect();
          return {
            natural: image.naturalWidth + 'x' + image.naturalHeight,
            rendered: Math.round(rect.width) + 'x' + Math.round(rect.height),
            complete: image.complete
          };
        });
      return JSON.stringify({
        width: state.width,
        pages: state.pages,
        byWidth: byWidth,
        probed: probed,
        scrollWidth: document.body ? document.body.scrollWidth : 0,
        contentWidth: Math.round(internal.layout.contentWidth()),
        textMaxRight: Math.round(internal.layout.textMaxRight()),
        bodyVisibility: bodyStyle.visibility,
        bodyDisplay: bodyStyle.display,
        bodyOverflow: bodyStyle.overflow,
        bodyChildCount: document.body.children.length,
        firstChild: firstChild ? firstChild.tagName + '.' + (firstChild.className || '') : '',
        firstChildPos: firstChildStyle ? firstChildStyle.position : '',
        firstChildSize: firstChild
          ? Math.round(firstChild.getBoundingClientRect().width) + 'x' +
            Math.round(firstChild.getBoundingClientRect().height)
          : '',
        images: imageProbe
      });
    }
  };
})();
