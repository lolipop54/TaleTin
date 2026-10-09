/* WebView 宿主页内部的字体、主题与首次显示能力。 */
(function () {
  'use strict';
  var internal = window.__gtHost = window.__gtHost || {};
  var state = internal.state;
  var scaledElements = [];
  var bookFont = null;
  var appliedFamily = '';
  var appliedBold = false;
  var appliedFontSize = 0;
  var appliedIndent = true;
  var appliedLineHeight = null;
  var appliedParagraphGap = null;

  function hasFixedPxFont() {
    try {
      var sheets = document.styleSheets || [];
      for (var i = 0; i < sheets.length; i++) {
        var owner = sheets[i].ownerNode;
        if (owner && owner.id === 'gt-override-style') continue;
        var rules = null;
        try {
          rules = sheets[i].cssRules;
        } catch (error) {
          continue;
        }
        if (!rules) continue;
        for (var j = 0; j < rules.length; j++) {
          var rule = rules[j];
          var size = rule.style && rule.style.fontSize;
          if (!size || size.indexOf('px') < 0) continue;
          var selector = (rule.selectorText || '').toLowerCase();
          if (selector.indexOf('body') >= 0 ||
              selector.indexOf('html') >= 0) return true;
          if (/(^|[\s,>~+])p([\s,{:.#>~+]|$)/.test(selector) ||
              selector.indexOf('div') >= 0) return true;
        }
      }
    } catch (error) {
      // 拿不到样式表时按常规书处理。
    }
    try {
      var probe = document.querySelectorAll('p,div');
      for (var k = 0; k < probe.length && k < 30; k++) {
        var inline = probe[k].style && probe[k].style.fontSize;
        if (inline && inline.indexOf('px') >= 0) return true;
      }
    } catch (error) {
      // 同上。
    }
    return false;
  }

  function measureRootPx() {
    var probe = document.createElement('div');
    probe.style.setProperty('font-size', '1rem', 'important');
    probe.style.setProperty('position', 'absolute');
    probe.style.setProperty('visibility', 'hidden');
    probe.textContent = 'x';
    document.body.appendChild(probe);
    var size = parseFloat(window.getComputedStyle(probe).fontSize);
    document.body.removeChild(probe);
    if (size > 0) return size;
    var rootPx = parseFloat(
      window.getComputedStyle(document.documentElement).fontSize);
    return rootPx > 0 ? rootPx : 16;
  }

  function measureBookFont() {
    var rootPx = document.body ? measureRootPx() : 16;
    var bodyPx = document.body
      ? parseFloat(window.getComputedStyle(document.body).fontSize)
      : 0;
    if (!bodyPx) bodyPx = rootPx;
    var textPx = 0;
    var longest = 0;
    var paragraphs = document.body ? document.body.querySelectorAll('p') : [];
    for (var i = 0; i < paragraphs.length && i < 200; i++) {
      var length = (paragraphs[i].textContent || '')
        .replace(/\s+/g, '').length;
      if (length < 8 || length <= longest) continue;
      var size = parseFloat(window.getComputedStyle(paragraphs[i]).fontSize);
      if (size > 0) {
        longest = length;
        textPx = size;
      }
    }
    if (!textPx) textPx = bodyPx;
    return { rootPx: rootPx, textPx: textPx };
  }

  function analyzeBookFont() {
    if (!bookFont) {
      var base = measureBookFont();
      bookFont = {
        rootPx: base.rootPx,
        textPx: base.textPx,
        fixed: hasFixedPxFont()
      };
    }
    return bookFont;
  }

  function markImageOnlyParagraphs() {
    var paragraphs = document.body.querySelectorAll('p');
    for (var i = 0; i < paragraphs.length; i++) {
      var paragraph = paragraphs[i];
      if (paragraph.querySelector('img') && !paragraph.textContent.trim()) {
        paragraph.setAttribute('data-gt-image-only', '');
      }
      var align = window.getComputedStyle(paragraph).textAlign;
      // 只给正文段落补两字缩进，目录、列表、表格、图注及居中章题保留原布局。
      if (paragraph.textContent.trim() && align !== 'center' && align !== 'right' &&
          !paragraph.closest('li,table,figure,nav,pre,[role="heading"]')) {
        paragraph.setAttribute('data-gt-indent', '');
      }
    }
    // 部分书用 div + br 承载正文，标记直接含文字的 div，避免修改纯容器/章题。
    var divs = document.body.querySelectorAll('div');
    for (var j = 0; j < divs.length; j++) {
      var align = window.getComputedStyle(divs[j]).textAlign;
      if (align === 'center' || align === 'right') continue;
      var directText = Array.prototype.some.call(divs[j].childNodes, function(node) {
        return node.nodeType === 3 && node.nodeValue.trim();
      });
      if (directText) {
        divs[j].setAttribute('data-gt-prose', '');
        if (!divs[j].closest('li,table,figure,nav,pre,[role="heading"]')) {
          divs[j].setAttribute('data-gt-indent', '');
        }
      }
    }
  }

  function markWideHeadings() {
    var headings = document.body.querySelectorAll('h1,h2,h3,h4,h5,h6');
    for (var i = 0; i < headings.length; i++) {
      var style = window.getComputedStyle(headings[i]);
      if (parseFloat(style.marginLeft) < 0 ||
          parseFloat(style.marginRight) < 0) {
        headings[i].setAttribute('data-gt-fit-heading', '');
      }
    }
  }

  function clearElementFontScale() {
    for (var i = 0; i < scaledElements.length; i++) {
      scaledElements[i].style.removeProperty('font-size');
    }
    scaledElements = [];
  }

  // px 写死的书先统一测量，再按同一个基准缩放，避免嵌套元素重复缩放。
  function applyElementFontScale(scale) {
    clearElementFontScale();
    if (!document.body || Math.abs(scale - 1) < 0.001) return;
    var nodes = [document.body];
    var children = document.body.querySelectorAll('*');
    for (var i = 0; i < children.length; i++) nodes.push(children[i]);
    var pending = [];
    for (var j = 0; j < nodes.length; j++) {
      var element = nodes[j];
      if (element.__gtBaseFont === undefined) {
        var size = parseFloat(window.getComputedStyle(element).fontSize);
        element.__gtBaseFont = size > 0 ? size : 0;
      }
      if (element.__gtBaseFont > 0) pending.push(element);
    }
    for (var k = 0; k < pending.length; k++) {
      pending[k].style.setProperty(
        'font-size', (pending[k].__gtBaseFont * scale) + 'px', 'important');
      scaledElements.push(pending[k]);
    }
  }

  function applyFontSize(fontSizePx) {
    var book = analyzeBookFont();
    var scale = book.textPx > 0 ? fontSizePx / book.textPx : 1;
    if (book.fixed) {
      applyElementFontScale(scale);
      return '';
    }
    clearElementFontScale();
    return 'html { font-size: ' + (book.rootPx * scale).toFixed(2) +
      'px !important; }\n';
  }

  function ensureOverrideStyle() {
    var element = document.getElementById('gt-override-style');
    if (!element) {
      element = document.createElement('style');
      element.id = 'gt-override-style';
      (document.head || document.documentElement).appendChild(element);
    }
    return element;
  }

  function applyStyle(options) {
    options = options || {};
    var css = '';
    // 正文强制两端对齐，段落末行仍靠左；章题保留原书对齐方式。
    css += 'body, body p:not([data-gt-image-only]), body li, body blockquote, body [data-gt-prose] {' +
      'text-align: justify !important; text-align-last: left !important;' +
      'text-justify: inter-character !important; hyphens: manual !important; }\n';
    var family = options.fontFamily !== undefined
      ? options.fontFamily : appliedFamily;
    var bold = options.bold !== undefined ? options.bold : appliedBold;
    var faceChanged = family !== appliedFamily || bold !== appliedBold;
    var marginChanged = false;
    var indentChanged = false;
    if (options.indent !== undefined) {
      indentChanged = options.indent !== appliedIndent;
      appliedIndent = options.indent;
    }
    if (options.marginPx !== undefined && options.marginPx !== null &&
        Math.round(options.marginPx) !== state.margin) {
      state.margin = Math.max(0, Math.round(options.marginPx));
      marginChanged = true;
    }
    var fontSizePx = options.fontSizePx
      ? Number(options.fontSizePx) : appliedFontSize;
    var fontChanged = fontSizePx > 0 && fontSizePx !== appliedFontSize;
    var lineHeight = options.lineHeight !== undefined
      ? options.lineHeight : appliedLineHeight;
    var paragraphGap = options.paragraphGapEm !== undefined
      ? options.paragraphGapEm : appliedParagraphGap;
    var spacingChanged = lineHeight !== appliedLineHeight ||
      paragraphGap !== appliedParagraphGap;
    var changingLayout = state.started &&
      (indentChanged || marginChanged || fontChanged || faceChanged || spacingChanged);
    var savedProgress;
    var savedAnchor = null;
    if (changingLayout) {
      savedProgress = state.pages <= 1 ? 0 : state.page / state.pages;
      savedAnchor = internal.dom.captureAnchor();
      if (savedAnchor && Math.floor(
          internal.dom.anchorOffsetX(savedAnchor) / state.width) !== state.page) {
        savedAnchor = null;
      }
    }
    if (fontSizePx > 0) {
      appliedFontSize = fontSizePx;
      css += applyFontSize(fontSizePx);
    }
    appliedFamily = family;
    appliedBold = bold;
    appliedLineHeight = lineHeight;
    appliedParagraphGap = paragraphGap;
    // 只覆盖正文间距，保留语义标题和纯图片段落的原书布局。
    var prose = 'body p:not([data-gt-image-only]), body li, body [data-gt-prose]';
    if (lineHeight !== null) {
      css += prose + ', body p:not([data-gt-image-only]) *, body li *, ' +
        'body [data-gt-prose] * { line-height: ' + lineHeight + ' !important; }\n';
    }
    if (paragraphGap !== null) {
      css += prose + ' { margin-top: 0 !important; margin-bottom: ' +
        paragraphGap + 'em !important; }\n';
    }
    if (family) {
      css += 'body, body * { font-family: ' + JSON.stringify(family) +
        ', sans-serif !important; }\n';
    }
    if (bold) css += 'body, body * { font-weight: 700 !important; }\n';
    var colors = options.colors;
    if (colors) {
      if (colors.bg) {
        css += 'html, body { background: ' + colors.bg + ' !important; }\n';
      }
      if (colors.text) {
        css += 'body { color: ' + colors.text + ' !important; }\n';
      }
      if (colors.link) {
        css += 'a { color: ' + colors.link + ' !important; }\n';
      }
    }
    if (appliedIndent) {
      css += 'body [data-gt-indent] { text-indent: 2em !important; }\n';
    } else {
      css += 'body p, body div { text-indent: 0 !important; }\n';
    }
    ensureOverrideStyle().textContent = css;
    // 表格字号单独收紧；不用缩放整个元素，长行仍由浏览器真实分栏跨页。
    Array.prototype.forEach.call(document.querySelectorAll('table'), function (table) {
      var columns = 1;
      Array.prototype.forEach.call(table.rows, function (row) {
        var count = 0;
        Array.prototype.forEach.call(row.cells, function (cell) { count += cell.colSpan || 1; });
        columns = Math.max(columns, count);
      });
      var size = Math.min(appliedFontSize || 16, Math.max(10, 24 - columns * 2));
      table.style.setProperty('font-size', size + 'px', 'important');
      Array.prototype.forEach.call(table.querySelectorAll('*'), function (element) {
        element.style.setProperty('font-size', 'inherit', 'important');
        element.style.setProperty('line-height', '1.4', 'important');
        element.style.setProperty('text-align', 'left', 'important');
      });
    });
    if ((fontChanged || marginChanged || indentChanged || faceChanged || spacingChanged) &&
        state.started) {
      internal.layout.relayout(
        true, marginChanged ? internal.layout.setupColumns : null,
        savedAnchor, savedProgress);
    }
    return true;
  }

  function revealContent() {
    var preload = document.getElementById('gt-preload');
    if (preload && preload.parentNode) preload.parentNode.removeChild(preload);
  }

  function whenContentReady(callback) {
    var waits = [];
    try {
      if (document.fonts && document.fonts.ready) {
        waits.push(document.fonts.ready);
      }
    } catch (error) {
      // 老 WebView 没有字体 API 时直接继续。
    }
    Array.prototype.slice.call(document.images).forEach(function (image) {
      // 已下载的图片也可能尚未解码，截图不能只等待 load 事件。
      if (image.decode) {
        waits.push(image.decode().catch(function () {}));
        return;
      }
      if (image.complete) return;
      waits.push(new Promise(function (resolve) {
        image.addEventListener('load', resolve, { once: true });
        image.addEventListener('error', resolve, { once: true });
      }));
    });
    if (waits.length === 0) {
      callback();
      return;
    }
    Promise.all(waits).then(callback, callback);
  }

  // 换字体时先下载并解码选中的那一种，旧正文继续显示；空串使用原书字体。
  function prepareFont(family, css) {
    // 字体选择页可能刚把新字体加入目录。只补当前字体的声明，保留旧字体
    // 声明到正文切换完成，加载期间旧页面不会突然退回系统字形。
    if (family && css) {
      var id = 'gt-device-font-' + family;
      if (!document.getElementById(id)) {
        var sheet = document.createElement('style');
        sheet.id = id; sheet.textContent = css; document.head.appendChild(sheet);
      }
    }
    if (!family || !document.fonts) return Promise.resolve();
    // 内置字体可能有独立粗体文件，标题和加粗正文也须准备后再重新分页。
    return Promise.all([400, 700].map(function (weight) {
      return document.fonts.load(weight + ' 16px ' + JSON.stringify(family));
    }));
  }

  function watchImages() {
    var pending = 0;
    Array.prototype.slice.call(document.images).forEach(function (image) {
      if (image.complete) return;
      pending++;
      var done = function () {
        pending--;
        if (pending <= 0) internal.layout.relayout(state.started);
      };
      image.addEventListener('load', done, { once: true });
      image.addEventListener('error', done, { once: true });
    });
  }

  internal.style = {
    apply: applyStyle,
    markImageOnlyParagraphs: markImageOnlyParagraphs,
    markWideHeadings: markWideHeadings,
    revealContent: revealContent,
    watchImages: watchImages,
    whenContentReady: whenContentReady,
    prepareFont: prepareFont
  };
})();
