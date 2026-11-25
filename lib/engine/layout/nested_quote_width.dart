part of 'display_box_layout.dart';

// 同一外层引用的文字、图片、表格及空框使用同一决定。只留当前宽度的结果，
// 显示树释放时一起回收，分屏或换字号时按新条件重算。
final _quoteWidths =
    Expando<Map<int, (double, LayoutOptions, StyleTable, bool)>>();

bool _quotesFit(
  DisplayTree tree,
  int root,
  StyleTable styles,
  LayoutOptions options,
  double available,
) {
  if (!tree.hasQuoteBelow.contains(root)) return false;
  final cache = _quoteWidths[tree] ??= {};
  final previous = cache[root];
  if (previous != null &&
      previous.$1 == available &&
      identical(previous.$2, options) &&
      identical(previous.$3, styles)) {
    return previous.$4;
  }
  // 可读下限定为八个当前正文字号的汉字。使用本列的真实内容宽度，
  // 百分比、边框、内边距均逐层计算；任一内层过窄则全组沿用首层缩进。
  final minimum =
      options.textScaler.scale(options.settings.fontSize.toDouble()) * 8;
  final pending = [(root, available)];
  var fits = true;
  while (pending.isNotEmpty && fits) {
    final (id, parentWidth) = pending.removeLast();
    final node = tree.nodes[id], element = node.element;
    var width = parentWidth;
    if (node.isBlock) {
      final style = styles[element.styleId ?? 0];
      final box = resolveBlockBox(
        style.box,
        DisplayBoxLayout.context(style, options, parentWidth),
      );
      width = DisplayBoxLayout._horizontal(style, options, parentWidth, box).$2;
    }
    if (id != root &&
        node.isBlock &&
        element.tag == 'blockquote' &&
        width < minimum) {
      fits = false;
    } else {
      for (final child in element.children) {
        if (tree.hiddenElements.contains(child)) continue;
        final childNode = tree.nodes[child];
        final tag = childNode.element.tag;
        if (const {'ol', 'ul', 'dl'}.contains(tag)) continue;
        if ((childNode.isBlock && tag == 'blockquote') ||
            tree.hasQuoteBelow.contains(child)) {
          pending.add((child, width));
        }
      }
    }
  }
  cache[root] = (available, options, styles, fits);
  return fits;
}
