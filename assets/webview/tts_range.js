/* 听书矩形层独立于 body 分栏；节点路径来自净化正文对照表。 */
(function () {
  'use strict';
  var nodes = new Map(), version = -1, current = null, overlay = null;
  function resolve(point) {
    var key = point.path.join('/'), node = nodes.get(key);
    if (!node) {
      node = document.body;
      point.path.forEach(function (i) { node = node && node.childNodes[i]; });
      if (!node || node.nodeType !== 3) throw Error('听书文本节点不存在');
      nodes.set(key, node);
    }
    if (point.offset < 0 || point.offset > node.length) throw Error('听书偏移越界');
    return node;
  }
  function range(from, to) {
    var r = document.createRange();
    r.setStart(resolve(from), from.offset);
    r.setEnd(resolve(to), to.offset);
    return r;
  }
  function layer() {
    if (overlay) return overlay;
    var root = document.createElement('div');
    root.id = 'gt-tts-layer';
    root.style.cssText = 'position:fixed;inset:0;pointer-events:none;z-index:2147483646;overflow:hidden';
    // 放在 body 外，不改变正文子节点路径或多栏宽度。
    document.documentElement.appendChild(root);
    overlay = root.attachShadow({mode:'open'});
    return overlay;
  }
  function clear(value) {
    if (value < version) return false;
    version = value; current = null;
    if (overlay) overlay.replaceChildren();
    return true;
  }
  function paint() {
    if (!current) return;
    var target = layer(); target.replaceChildren();
    var rects = range(current.from, current.to).getClientRects();
    var width = innerWidth, height = innerHeight;
    Array.prototype.forEach.call(rects, function (r) {
      var left = Math.max(0,r.left), right = Math.min(width,r.right);
      var top = Math.max(0,r.top), bottom = Math.min(height,r.bottom);
      if (right <= left || bottom <= top) return;
      var box = document.createElement('div');
      box.style.cssText = 'position:absolute;pointer-events:none;opacity:.48;left:'+left+
        'px;top:'+top+'px;width:'+(right-left)+'px;height:'+(bottom-top)+
        'px;background:'+current.color;
      target.appendChild(box);
    });
  }
  function set(value) {
    if (value.version < version) return false;
    // 先核对两个端点，错误不留下半幅高亮。
    range(value.from, value.to);
    version = value.version; current = value; paint(); return true;
  }
  function rect(point) {
    var node = resolve(point), offset = Math.min(point.offset, node.length - 1);
    if (offset < 0) return null;
    var end = offset + 1;
    var code = node.data.charCodeAt(offset);
    if (code >= 0xD800 && code <= 0xDBFF) end++;
    var r = document.createRange(); r.setStart(node, offset);
    r.setEnd(node, Math.min(end,node.length));
    return r.getClientRects()[0] || null;
  }
  // 只查询几何，不切临时页、不上报位置；长节点二分查每个跨页边界。
  function boundaries(points, state) {
    var result = [], previous = -1;
    function page(point) {
      var r = rect(point);
      return r ? Math.floor((r.left + state.page * state.width + 1) / state.width) : -1;
    }
    points.forEach(function (point) {
      var node = resolve({path:point.path,offset:0});
      if (!node.length) return;
      var offset = 0, first = page({path:point.path,offset:0});
      if (first < 0) return;
      if (first !== previous) result.push({path:point.path,offset:0});
      var last = page({path:point.path,offset:node.length-1});
      while (first < last) {
        var lo = offset+1, hi = node.length-1;
        while (lo < hi) {
          var mid = (lo+hi)>>1;
          if (page({path:point.path,offset:mid}) > first) hi=mid; else lo=mid+1;
        }
        // 不让页首落入代理对中间。
        if (lo > 0 && /[\uDC00-\uDFFF]/.test(node.data[lo])) lo--;
        if (lo <= offset) break;
        offset=lo; first=page({path:point.path,offset:lo});
        result.push({path:point.path,offset:lo});
      }
      previous=last;
    });
    return result;
  }
  window.__gtTts = {set:set, clear:clear, paint:paint, rect:rect, boundaries:boundaries};
})();
