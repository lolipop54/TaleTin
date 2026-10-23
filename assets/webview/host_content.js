/* DOM 位置转内容比例，参数来自 Dart 的同一份净化正文对照表。 */
(function () {
  'use strict';
  var internal = window.__gtHost, total = 0, byNode = new WeakMap();
  function set(value) {
    byNode = new WeakMap(); total = value.total;
    value.nodes.forEach(function (item) {
      var node = internal.dom.nodeOfPoint(item);
      if (node) byNode.set(node, item);
    });
  }
  function fraction(point) {
    if (!point || !total) return null;
    var node = internal.dom.nodeOfPoint(point), item = node && byNode.get(node);
    if (!item) return null;
    var offset = 0;
    if (!item.element) {
      var raw = node.nodeValue.slice(0, Math.max(0, Math.min(node.length, point.offset)));
      if (item.breaks.length) {
        var omit = new Set(item.breaks);
        raw = raw.split('').filter(function (_, i) { return !omit.has(i); }).join('');
      }
      offset = raw.replace(/[\s\u00a0\u3000]+/g, ' ').length;
      if (item.absorbed && offset > 0) offset--;
      offset = Math.max(0, Math.min(item.length, offset - item.hidden));
    }
    return Math.max(0, Math.min(1, (item.start + offset) / total));
  }
  internal.content = {set: set, fraction: fraction, hasNode: function (node) { return byNode.has(node); },
    fractionForPage: function (page) { return fraction(internal.index.pointForPage(page)); }};
})();
