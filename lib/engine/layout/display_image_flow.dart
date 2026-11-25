part of 'display_tree.dart';

/// 图片不占正文字符。由图片的 DOM 身份找回段内独占一行的父块，同位的脚注仍归原处。
Map<int, DisplayNode> _imageOnlyWrappers(
  DisplaySourceIndex source,
  List<DisplayNode> nodes,
  StyleTable styles,
  Set<int> hidden,
) {
  final result = <int, DisplayNode>{};
  final textContent = <int, bool>{};
  bool containsText(DisplayNode node) => textContent.putIfAbsent(
    node.element.id,
    () =>
        !hidden.contains(node.element.id) &&
        (node.element.ranges.any((r) => r.end > r.start) ||
            node.children.any(containsText)),
  );
  for (final image in nodes) {
    final e = image.element;
    if (e.role != 'image' || e.ranges.isEmpty || hidden.contains(e.id)) {
      continue;
    }
    final range = e.ranges.first;
    if (range.start != range.end) continue;
    final owner = source.ownerOfBlock(range.block)?.id;
    if (owner == null || owner == e.id) continue;
    var parent = image.parent;
    while (parent != null && !parent.isBlock && parent.element.id != owner) {
      parent = parent.parent;
    }
    if (parent == null ||
        parent.element.id == owner ||
        parent.element.firstBlock != null ||
        !parent.isBlock ||
        containsText(parent)) {
      continue;
    }
    final display = styles[parent.element.styleId ?? 0].block;
    if (display.float == FloatSpec.left ||
        display.float == FloatSpec.right ||
        display.position == PositionSpec.absolute ||
        display.position == PositionSpec.fixed) {
      continue;
    }
    // 只接管同一正文所有者内部的块。独立插图继续由图片块测量。
    var ancestor = parent.parent;
    while (ancestor != null && ancestor.element.id != owner) {
      ancestor = ancestor.parent;
    }
    if (ancestor != null) result[e.id] = parent;
  }
  return result;
}
