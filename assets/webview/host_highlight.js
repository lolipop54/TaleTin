/* 原书持久高亮层：把笔记与高亮记录画在正文之上（实现计划 S6）。
 *
 * 与听书高亮同一套几何口径：矩形由 DOM Range 量出来，但**位置存的是内容坐标**
 * （不含当前页位移），整层跟着正文一起平移——翻页、拖动、换章时高亮和文字
 * 严丝合缝，不需要每帧重新量。矩形用绝对定位的方块画，不碰正文结构、不改
 * 多栏宽度、不吃触摸（pointer-events: none），原书 CSS 与分页都不受影响。
 *
 * 命中测试只用已画出的方块：点击正文时先问「这一点压在哪条高亮上」，
 * 由 Dart 打开那条记录的菜单；这里只做几何，不保存任何业务数据。
 */
(function () {
  'use strict';
  var internal = window.__gtHost = window.__gtHost || {};
  var state = internal.state;

  var overlay = null;
  var track = null;

  /// 当前高亮：`{id, from, to, color}`，由 Dart 下发
  var items = [];
  // 临时选区也用内容坐标绘制，随正文平移并进入翻页截图，不停在旧页上。
  var selection = null;
  var dragEnd = null;
  var handles = [];

  /// 已画出的方块（内容坐标），命中测试用
  var painted = [];
  var thoughts = [];

  // 与正文一起移动，不进入 body，因此不会改变 DOM 文本路径或分页。
  function thought(item, rect, offset) {
    var color = item.thoughtColor || '#2468c9';
    var right = rect.right + offset;
    var pageLeft = Math.floor((right - 1) / state.width) * state.width;
    var left = Math.min(right + 2, pageLeft + state.width - 18);
    var top = Math.max(0, rect.top - 4);
    var mark = document.createElement('div');
    mark.style.cssText = 'position:absolute;pointer-events:none;left:' + left +
      'px;top:' + top + 'px;width:16px;height:12px;border-radius:2px;background:' + color + ';' +
      'background-image:linear-gradient(white,white),linear-gradient(white,white);' +
      'background-size:8px 1px,8px 1px;background-position:4px 4px,4px 8px;background-repeat:no-repeat';
    var tip = document.createElement('div');
    tip.style.cssText = 'position:absolute;left:3px;top:11px;border-top:5px solid ' + color + ';border-right:5px solid transparent';
    mark.appendChild(tip);
    track.appendChild(mark);
    thoughts.push({id: item.id, left: left, top: top, width: 16, height: 16});
  }

  function thoughtMarkers() {
    var offset = (state.page || 0) * (state.width || 0);
    return thoughts.filter(function (r) {
      return r.left >= offset && r.left + r.width <= offset + state.width;
    }).map(function (r) {
      return {id: r.id, left: r.left - offset, top: r.top, width: r.width, height: r.height};
    });
  }

  var version = -1;

  /// 本章的高亮是否已经下发过（含「确实没有高亮」的空列表）
  var ready = false;

  /// 等下发到位后回调：正文首次显示前用它把高亮一起画出来，不再先见正文再补底色
  var waiting = [];

  function settle() {
    ready = true;
    var callbacks = waiting;
    waiting = [];
    for (var i = 0; i < callbacks.length; i++) callbacks[i]();
  }

  /// 到手就回调；[timeout] 毫秒内没等到也回调（宁可有先后，不能一直不显示正文）
  function whenReady(callback, timeout) {
    if (ready) {
      callback();
      return;
    }
    var done = false;
    function once() {
      if (done) return;
      done = true;
      callback();
    }
    waiting.push(once);
    setTimeout(function () {
      if (done) return;
      var index = waiting.indexOf(once);
      if (index >= 0) waiting.splice(index, 1);
      once();
    }, timeout || 300);
  }

  function layer() {
    if (track) return track;
    var root = document.createElement('div');
    root.id = 'gt-mark-layer';
    root.style.cssText = 'position:fixed;inset:0;pointer-events:none;' +
      'z-index:2147483645;overflow:hidden';
    // 放在 body 外：不改变正文子节点路径，也不参与多栏宽度计算
    document.documentElement.appendChild(root);
    var shadow = root.attachShadow({mode: 'open'});
    track = document.createElement('div');
    track.style.cssText = 'position:absolute;inset:0;will-change:transform';
    shadow.appendChild(track);
    overlay = shadow;
    return track;
  }

  /// 节点路径（相对 body）→ DOM 文本节点，与听书高亮同一套解析
  function resolve(point) {
    var node = document.body;
    for (var i = 0; i < point.path.length; i++) {
      node = node && node.childNodes[point.path[i]];
    }
    if (!node || node.nodeType !== 3) return null;
    return node;
  }

  function box(left, top, width, height, color, id) {
    var element = document.createElement('div');
    element.style.cssText = 'position:absolute;pointer-events:none;opacity:' + (id ? '.45;' : '1;') +
      'left:' + left + 'px;top:' + top + 'px;width:' + width + 'px;' +
      'height:' + height + 'px;background:' + color;
    track.appendChild(element);
    if (id) painted.push({id: id, left: left, top: top, width: width, height: height});
  }

  // 静止手柄使用内容坐标，随正文移动，也进入翻页截图。
  // 拖动端由 Flutter 跟手绘制，另一端仍留在它自己的文字旁。
  function handle(rect, atRight, offset, color, atEnd) {
    var x = (atRight ? rect.right : rect.left) + offset;
    var root = document.createElement('div');
    root.style.cssText = 'position:absolute;pointer-events:none;' +
      'left:' + x + 'px;top:' + rect.bottom + 'px;width:0;height:0';
    var line = document.createElement('div');
    var height = rect.bottom - rect.top;
    // 与 Flutter 一致：圆心在文字底边下2px，半径5px，上缘压住高亮3px。
    line.style.cssText = 'position:absolute;left:-0.75px;top:' + (-height) +
      'px;width:1.5px;height:' + (height + 2) + 'px;background:' + color;
    var circle = document.createElement('div');
    circle.style.cssText = 'position:absolute;box-sizing:border-box;left:-5px;top:-3px;' +
      'width:10px;height:10px;border-radius:50%;border:1px solid white;background:' + color;
    root.appendChild(line);
    root.appendChild(circle);
    root.style.visibility = dragEnd === atEnd ? 'hidden' : 'visible';
    track.appendChild(root);
    handles.push({element: root, atEnd: atEnd});
  }

  function setSelectionDrag(value) {
    dragEnd = value;
    for (var i = 0; i < handles.length; i++) {
      handles[i].element.style.visibility = dragEnd === handles[i].atEnd ? 'hidden' : 'visible';
    }
  }

  /// 重画全部高亮。矩形换算成内容坐标，之后整层跟着正文平移。
  function render() {
    var offset = (state.page || 0) * (state.width || 0);
    layer();
    track.replaceChildren();
    painted = [];
    thoughts = [];
    handles = [];
    var visible = selection ? items.concat([selection]) : items;
    for (var i = 0; i < visible.length; i++) {
      var item = visible[i];
      var from = resolve(item.from), to = resolve(item.to);
      if (!from || !to) continue;
      // 与选区同一套矩形：两端跳过空白、首行左沿夹到起点字（缩进不算高亮）
      var rects = internal.selection.rangeBoxes(item.from, item.to);
      if (!rects) continue;
      for (var j = 0; j < rects.length; j++) {
        var rect = rects[j];
        box(rect.left + offset, rect.top, rect.right - rect.left,
          rect.bottom - rect.top, item.color, item.id);
      }
      if (item.id && item.hasThought && rects.length) {
        thought(item, rects[rects.length - 1], offset);
      }
      if (!rects.length && !item.id && item.handleColor) {
        // 两端暂时重合时仍保留光标手柄，拖动不会因选区没有面积而中断。
        var caret = internal.selection.rects(item.from, item.to);
        rects = caret ? caret.rects : [];
      }
      if (!item.id && item.handleColor && rects.length) {
        // 与 Flutter 触摸层一样取首末字，不从底色横带推断端点。
        var endpoints = internal.selection.rangeEndpoints(item.from, item.to);
        if (!endpoints || !endpoints.leading || !endpoints.trailing) continue;
        handle(endpoints.leading, false, offset, item.handleColor, item.reversed === true);
        handle(endpoints.trailing, true, offset, item.handleColor, item.reversed !== true);
        var previous = internal.selection.continuationAnchor(item.from, endpoints.leading, true);
        if (previous) {
          handle(previous, false, offset, item.handleColor, item.reversed === true);
        }
        var continuation = internal.selection.continuationAnchor(item.to, endpoints.trailing);
        if (continuation) {
          handle(continuation, false, offset, item.handleColor, item.reversed !== true);
        }
      }
    }
    move(0, false);
  }

  /// 整层跟着正文平移（翻页、拖动、重排都用它）
  function move(dx, animate, duration) {
    if (!track) return;
    var offset = (state.page || 0) * (state.width || 0);
    track.style.transition = animate
      ? 'transform ' + (duration || 200) + 'ms cubic-bezier(0.215, 0.61, 0.355, 1)'
      : 'none';
    track.style.transform = 'translateX(' + (-offset + dx) + 'px)';
  }

  /// 下发高亮列表：版本旧的（例如换章前发出的）直接丢掉
  function set(value, deferRender) {
    settle();
    if (!value || value.version < version) return false;
    version = value.version;
    items = value.items || [];
    if (!deferRender) render();
    return true;
  }

  // 不参与持久高亮的版本与命中，也不写笔记数据。
  function setSelection(value) {
    selection = value;
    if (!value) dragEnd = null;
    render();
  }

  /// 清掉这一章的高亮（换章、离开原书排版时）
  function clear(value) {
    settle();
    var token = value === undefined || value === null ? version + 1 : value;
    if (token < version) return false;
    version = token;
    items = [];
    if (track) {
      track.replaceChildren();
      painted = [];
      thoughts = [];
    }
    return true;
  }

  /// 这一点压在哪条高亮上？返回它的 id，没有就返回空串。
  ///
  /// 只看已经画出来的方块，因此「看得见」和「点得到」始终一致。
  function hitAt(x, y) {
    var contentX = x + (state.page || 0) * (state.width || 0);
    for (var i = painted.length - 1; i >= 0; i--) {
      var rect = painted[i];
      if (contentX < rect.left || contentX > rect.left + rect.width) continue;
      if (y < rect.top || y > rect.top + rect.height) continue;
      return rect.id;
    }
    return '';
  }

  internal.highlight = {
    clear: clear,
    hitAt: hitAt,
    thoughtMarkers: thoughtMarkers,
    whenReady: whenReady,
    move: move,
    render: render,
    setSelection: setSelection,
    setSelectionDrag: setSelectionDrag,
    set: set
  };
})();
