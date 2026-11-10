part of 'display_tree.dart';

/// 混合内容按“连续行内内容／块级子元素”分组。匿名节点只引用正文范围，
/// 不新增正文块；原 DOM 的 parent 仍保存在 DisplayElement 中。
void _groupAnonymousFlow(List<DisplayNode> nodes) {
  for (final parent in nodes.where((n) => n.isBlock).toList()) {
    final blocks = parent.children.where((n) => n.isBlock).toList();
    final anonymous = <DisplayNode>[];
    final byBlock = <int, List<DisplayTextRange>>{};
    for (final child in blocks) {
      for (final range in child.element.ranges) {
        (byBlock[range.block] ??= []).add(range);
      }
    }
    for (final cuts in byBlock.values) {
      cuts.sort((a, b) => a.start.compareTo(b.start));
    }
    for (final range in parent.element.ranges) {
      var cursor = range.start;
      final cuts = (byBlock[range.block] ?? const <DisplayTextRange>[]).where(
        (r) => r.end > range.start && r.start < range.end,
      );
      void add(int start, int end) {
        if (end <= start) return;
        final element = DisplayElement(
          id: nodes.length,
          parent: parent.element.id,
          nodeId: parent.element.nodeId,
          tag: '#anonymous',
          role: 'anonymous',
          firstBlock: range.block,
          lastBlock: range.block,
          children: const [],
          ranges: [DisplayTextRange(range.block, start, end)],
        );
        final node = DisplayNode(
          element: element,
          display: DisplaySpec.block,
          anonymous: true,
        )..parent = parent;
        for (final child in parent.children.where((n) => !n.isBlock)) {
          if (child.element.ranges.any(
            (r) => r.block == range.block && r.start >= start && r.end <= end,
          )) {
            node.children.add(child);
            child.parent = node;
          }
        }
        nodes.add(node);
        anonymous.add(node);
      }

      for (final cut in cuts) {
        if (cut.start > cursor) add(cursor, cut.start);
        if (cut.end > cursor) cursor = cut.end;
      }
      add(cursor, range.end);
    }
    if (anonymous.isEmpty) continue;
    parent.children.removeWhere(
      (n) => anonymous.any((a) => a.children.contains(n)),
    );
    parent.children.addAll(anonymous);
    parent.children.sort((a, b) {
      final ar = a.element.ranges.firstOrNull,
          br = b.element.ranges.firstOrNull;
      final first = (ar?.block ?? a.element.anchor).compareTo(
        br?.block ?? b.element.anchor,
      );
      return first != 0 ? first : (ar?.start ?? 0).compareTo(br?.start ?? 0);
    });
  }
}
