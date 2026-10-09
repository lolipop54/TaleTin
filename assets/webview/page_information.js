/* 信息区与正文使用同一次 CSS 平移；只维护当前及相邻页，避免按整章页数建 DOM。 */
(function () {
  'use strict';
  var data = null, host, track, style, rows = new Map(), signature = '';
  var rendered = null, returnPage = null;
  var bookmarkPoints = [], bookmarkMap = null;
  // 页码只在排版或书签变化时计算；翻页与拖动不遍历正文。
  function bookmarkPages() {
    if (bookmarkMap !== null) return bookmarkMap;
    var internal = window.__gtHost;
    if (!internal || !internal.state.width || !internal.state.started) return {};
    bookmarkMap = {};
    bookmarkPoints.forEach(function(item) {
      var rect;
      if (item.point.element) {
        var element = document.body;
        item.point.path.forEach(function(i) {element = element.childNodes[i];});
        rect = element.getBoundingClientRect();
      } else rect = window.__gtTts.rect(item.point);
      if (rect) bookmarkMap[item.id] = Math.max(0, Math.min(internal.state.pages - 1,
        Math.floor((internal.layout.toContentX(rect.left) + 1) / internal.state.width)));
    });
    return bookmarkMap;
  }
  function ensure() {
    if (host) return;
    host = document.createElement('gt-page-info');
    host.style.cssText = 'all:initial!important;position:fixed!important;inset:0!important;pointer-events:none!important;overflow:hidden!important;z-index:1!important';
    var shadow = host.attachShadow({mode:'closed'});
    style = document.createElement('style');
    track = document.createElement('div');
    track.style.cssText = 'position:absolute;inset:0;will-change:transform';
    shadow.append(style, track);
    document.documentElement.appendChild(host);
  }
  function render(state) {
    // 同一页拖动只更新 transform；不要每个触点都序列化数据、遍历信息节点。
    if (rendered && rendered.page === state.page && rendered.width === state.width &&
        rendered.pages === state.pages && rendered.started === state.started) return;
    rendered = {page:state.page,width:state.width,pages:state.pages,started:state.started};
    ensure();
    var marks = bookmarkPages();
    if (data && data.searchMenu && returnPage === null) returnPage = state.page;
    host.style.setProperty('visibility', data && (data.visible || data.searchMenu || Object.keys(marks).length) && data.paintInHost !== false && state.started ? 'visible' : 'hidden', 'important');
    if (!data || !state.width) return;
    var key = JSON.stringify([data, state.width, state.pages, marks]);
    if (key !== signature) {
      rows.forEach(function(row) { row.remove(); }); rows.clear(); signature = key;
      style.textContent = '.page{position:absolute;top:0;bottom:0;font-family:serif;color:' + data.color + ';font-weight:400;line-height:1.4}' +
      'header,footer{position:absolute;left:' + data.inset + 'px;right:' + data.inset + 'px;display:flex;align-items:center;justify-content:space-between}' +
      'header{top:16px;gap:12px;font-size:' + data.headerSize + 'px}header span{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}' +
      'header span{flex:1;min-width:0}' +
      'footer{bottom:' + (data.bottomInset + 12) + 'px;font-size:' + data.footerSize + 'px}footer .clock{position:absolute;left:50%;transform:translateX(-50%)}' +
      '.battery{display:flex;align-items:center;gap:4px}svg{width:14px;height:14px}';
    }
    // 翻页前后共用同一组相邻节点，过渡中不移动旧节点的逻辑页位置。
    var first = Math.max(0, state.page - 1), last = Math.min(state.pages - 1, state.page + 1);
    rows.forEach(function(row, page) { if (page < first || page > last) {row.remove(); rows.delete(page);} });
    for (var page = first; page <= last; page++) {
      if (rows.has(page)) continue;
      var row = document.createElement('section'); row.className = 'page';
      row.style.left = (page * state.width) + 'px'; row.style.width = state.width + 'px';
      var header = document.createElement('header'), footer = document.createElement('footer');
      function text(parent, value, className) {
        var span = document.createElement('span'); span.textContent = value;
        if (className) span.className = className; parent.appendChild(span); return span;
      }
      text(header, data.chapter);
      text(footer, ((data.start + (data.end - data.start) * page / state.pages) * 100).toFixed(2) + '%');
      text(footer, data.clock, 'clock');
      if (data.battery !== null) {
        var battery = text(footer, data.battery + '%', 'battery');
        // 五格的范围及尺寸与 Flutter 信息区一致；动态值只用于格数。
        var count = Math.ceil(Math.max(0, Math.min(100, data.battery)) / 20), cells = '';
        for (var cell = 0; cell < count; cell++) {
          cells += '<rect x="' + (5 + cell * 2.6) + '" y="9" width="1.6" height="6" fill="currentColor" stroke="none"/>';
        }
        battery.insertAdjacentHTML('beforeend', '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="7" width="16" height="10" rx="2"/><path d="M21 10v4"/>' + cells + '</svg>');
      }
      if (data.visible) row.append(header, footer);
      if (Object.keys(marks).some(function(id) {return marks[id] === page;})) {
        var ribbon = document.createElement('div'); ribbon.className = 'bookmark-ribbon';
        ribbon.style.cssText = 'position:absolute;top:0;right:' + data.bookmarkRibbonRight + 'px;width:16px;height:28px;filter:drop-shadow(0 1px 1px #3b3d3f4d)';
        ribbon.innerHTML = data.bookmarkRibbon;
        ribbon.firstChild.style.cssText = 'width:100%;height:100%;display:block';
        row.appendChild(ribbon);
      }
      if (data.searchMenu && page === returnPage) {
        // 搜索菜单属于书页，沿用相同的平移与相邻页；SVG 仅来自应用固定路径。
        var menu = document.createElement('div');
        menu.innerHTML = data.searchMenu;
        // 尺寸取自同一份应用SVG，菜单改样式时不会和Flutter点击区错位。
        menu.style.cssText = 'position:absolute;bottom:40px;left:50%;width:' +
          menu.firstChild.getAttribute('width') + 'px;height:' +
          menu.firstChild.getAttribute('height') + 'px;transform:translateX(-50%)';
        menu.firstChild.style.cssText = 'width:100%;height:100%;display:block';
        row.appendChild(menu);
      }
      track.appendChild(row); rows.set(page, row);
    }
  }
  window.__gtInformation = {
    currentPoint: function() {
      var anchor = window.__gtHost.dom.captureAnchor();
      if (!anchor || anchor.node.nodeType !== 3) {
        var image = Array.from(document.images).find(function(item) {
          var r = item.getBoundingClientRect();
          return r.width && r.height && r.right > 0 && r.left < window.__gtHost.state.width;
        });
        if (!image) return null;
        anchor = {node:image,offset:0};
      }
      var node = anchor.node, path = [];
      while (node !== document.body) {
        var parent = node.parentNode;
        path.push(Array.prototype.indexOf.call(parent.childNodes, node)); node = parent;
      }
      return {path:path.reverse(),offset:anchor.offset,element:anchor.node.nodeType !== 3};
    },
    setBookmarks: function(points) {
      bookmarkPoints = points; this.invalidateBookmarks();
      var internal = window.__gtHost;
      if (internal && internal.state.started) this.move(internal.state, 0, false);
    },
    invalidateBookmarks: function() {bookmarkMap = null; rendered = null;},
    bookmarkPages: bookmarkPages,
    configure: function(value) {
      var old = this.insets();
      if (!value || !value.searchMenu || !data || !data.searchMenu || value.searchMenu !== data.searchMenu) returnPage = null;
      data = value; rendered = null; return old !== this.insets();
    },
    top: function() { return 24 + (data ? data.top : 0); },
    insets: function() { return 48 + (data ? data.top + data.bottom : 0); },
    move: function(state, dx, animate, duration) {
      render(state);
      track.style.transition = animate ? 'transform ' + (duration || 200) + 'ms cubic-bezier(0.215, 0.61, 0.355, 1)' : 'none';
      track.style.transform = 'translateX(' + (-state.page * state.width + dx) + 'px)';
    }
  };
})();
