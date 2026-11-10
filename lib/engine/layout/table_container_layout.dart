import '../styles/style_table.dart';
import 'display_tree.dart';
import 'layout_options.dart';
import 'measured_block.dart';
import 'display_box_layout.dart';

/// 表格和普通块共用祖先容器；列宽计算只接收已经扣完外框的内容宽度。
class TableContainerLayout {
  const TableContainerLayout(
    this.frames,
    this.left,
    this.right,
    this.top,
    this.bottom,
  );
  final List<ContainerBoxFrame> frames;
  final double left, right, top, bottom;
  static TableContainerLayout build(
    String blockId,
    DisplayTree? tree,
    StyleTable? styles,
    LayoutOptions options, {
    String? lastBlockId,
  }) {
    final index = tree?.blockIndexById[blockId];
    final lastIndex = tree?.blockIndexById[lastBlockId ?? blockId];
    if (index == null || tree?.authoritative != true) {
      return const TableContainerLayout([], 0, 0, 0, 0);
    }
    final chain = <DisplayContainer>[];
    final tail = tree!.chainOf(lastIndex ?? index);
    for (final container in tree.chainOf(index)) {
      chain.add(
        DisplayContainer(
          elementId: container.elementId,
          styleId: container.styleId,
          first: container.first,
          last: tail.any((c) => c.elementId == container.elementId && c.last),
          role: container.role,
          tag: container.tag,
        ),
      );
      if (container.role == 'table') break;
    }
    final geometry = DisplayBoxLayout.resolve(chain, styles, options);
    return TableContainerLayout(
      geometry.frames,
      geometry.left,
      geometry.right,
      geometry.top,
      geometry.bottom,
    );
  }
}
