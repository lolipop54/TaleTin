import '../../domain/models/book_document.dart';
import '../styles/style_box_value.dart';
import '../styles/style_table.dart';
import 'display_box_layout.dart';
import 'display_tree.dart';
import 'layout_options.dart';
import 'measured_block.dart';

/// 汇总未分页时的实际块高。同一逻辑测量供翻页和滚动使用。
/// 只在容器结束时补足作者留白，文字和表格仍按自己的块号与行号排。
class ContainerFlowSizing {
  static ContainerFlowSizing? build(
    DisplayTree tree,
    StyleTable styles,
    LayoutOptions options,
  ) {
    if (!tree.authoritative) return null;
    final sizing = ContainerFlowSizing._(tree, styles, options);
    return sizing._targets.isEmpty ? null : sizing;
  }

  ContainerFlowSizing._(
    DisplayTree tree,
    StyleTable styles,
    LayoutOptions options,
  ) : _order = tree.blockIndexById {
    for (final node in tree.nodes) {
      final element = node.element;
      final first = element.firstBlock, last = element.lastBlock;
      if (element.id == 0 ||
          !node.isBlock ||
          first == null ||
          last == null ||
          element.table != null ||
          tree.hiddenElements.contains(element.id) ||
          (first == last &&
              tree.source?.ownerOfBlock(first)?.id == element.id)) {
        continue;
      }
      final size = styles[element.styleId ?? 0].size;
      if (size.height?.isAuto != false && size.minHeight?.isAuto != false) {
        continue;
      }
      // 定位与独立浮动框走原有各自的排布，不能当作普通块流累加高度。
      DisplayNode? ancestor = node;
      while (ancestor != null) {
        final style = styles[ancestor.element.styleId ?? 0].block;
        if (style.position == PositionSpec.absolute ||
            style.position == PositionSpec.fixed ||
            (style.float != null && style.float != FloatSpec.none)) {
          break;
        }
        ancestor = ancestor.parent;
      }
      if (ancestor != null) continue;
      var start = first, end = last;
      while (start <= end && tree.hiddenBlocks.contains(start)) {
        start++;
      }
      while (end >= start && tree.hiddenBlocks.contains(end)) {
        end--;
      }
      if (start > end) continue;
      final startGeometry = <int, ContainerHeightGeometry>{};
      DisplayBoxLayout.resolve(
        tree.chainOf(start),
        styles,
        options,
        tree: tree,
        heightGeometry: startGeometry,
        collapseMargins: true,
      );
      final geometry = startGeometry[element.id];
      if (geometry == null || geometry.minimum <= 0) continue;
      final endGeometry = <int, ContainerHeightGeometry>{};
      final ending = DisplayBoxLayout.resolve(
        tree.chainOf(end),
        styles,
        options,
        tree: tree,
        heightGeometry: endGeometry,
        collapseMargins: true,
      );
      final target = _SizedContainer(
        id: element.id,
        first: start,
        last: end,
        minimum: geometry.minimum,
        top: geometry.top,
        bottom: endGeometry[element.id]?.bottom ?? 0,
        frames: ending.frames.where((f) => f.elementId <= element.id).toList(),
      );
      _targets[element.id] = target;
      (_starts[start] ??= []).add(target);
      (_ends[end] ??= []).add(target);
    }
  }

  final Map<String, int> _order;
  final _targets = <int, _SizedContainer>{};
  final _starts = <int, List<_SizedContainer>>{};
  final _ends = <int, List<_SizedContainer>>{};
  final _top = <int, double>{};
  double _bottom = 0;

  /// 页窗口可以从容器开头或容器之后恢复。容器中间的断点缺少前面各块的高度。
  bool canRestartAt(String blockId, int line) {
    final ordinal = _order[blockId];
    return ordinal == null ||
        !_targets.values.any(
          (box) =>
              (ordinal > box.first || (ordinal == box.first && line != 0)) &&
              ordinal <= box.last,
        );
  }

  List<ContainerFlowTail> add(
    List<MeasuredBlock> blocks, {
    required double gap,
    required double height,
    bool firstSlice = true,
    bool lastSlice = true,
  }) {
    final y = _bottom + gap;
    _bottom = y + height;
    final closing = <int, (double, List<ContainerBoxFrame>)>{};
    for (final block in blocks) {
      if (block.isDecoration && block.kind != BlockKind.divider) {
        // 空的首尾子元素也可能有外框。它的借用块号不代表它在 DOM 中的位置。
        for (final frame in block.containerBoxes) {
          if (!_targets.containsKey(frame.elementId)) continue;
          if (frame.first) {
            _top.putIfAbsent(frame.elementId, () => y + frame.top);
          }
          if (frame.last) {
            closing[frame.elementId] = (frame.bottom, block.containerBoxes);
          }
        }
        continue;
      }
      if (block.isPageImage || block.pageTop != null) continue;
      final ordinal = _order[block.blockId];
      if (firstSlice) {
        for (final target in _starts[ordinal] ?? const <_SizedContainer>[]) {
          _top.putIfAbsent(target.id, () => y + target.top);
        }
      }
      if (lastSlice) {
        for (final target in _ends[ordinal] ?? const <_SizedContainer>[]) {
          // 整个表格以一个单元提交。单元格只提供源编号，盒子采用共同的末端几何。
          final frame = target.frames
              .where((f) => f.elementId == target.id)
              .firstOrNull;
          if (frame?.last == false) continue; // 尾部还有一个独立空盒。
          closing[target.id] = (target.bottom, target.frames);
        }
      }
    }
    if (closing.isEmpty) return const [];
    final tails = <ContainerFlowTail>[];
    // 内层补足的留白也是外层自然高度的一部分。
    for (final id in closing.keys.toList()..sort((a, b) => b.compareTo(a))) {
      final top = _top.remove(id);
      if (top == null) continue;
      final (outsideBottom, frames) = closing[id]!;
      final extra = _targets[id]!.minimum - (_bottom - top - outsideBottom);
      if (extra <= .001) continue;
      _bottom += extra;
      tails.add(
        ContainerFlowTail(extra, [
          for (final frame in frames)
            if (frame.elementId <= id)
              ContainerBoxFrame(
                elementId: frame.elementId,
                box: frame.box,
                first: false,
                last: frame.last,
                left: frame.left,
                width: frame.width,
                bottom: frame.bottom,
              ),
        ]),
      );
    }
    return tails;
  }
}

class _SizedContainer {
  const _SizedContainer({
    required this.id,
    required this.first,
    required this.last,
    required this.minimum,
    required this.top,
    required this.bottom,
    required this.frames,
  });

  final int id, first, last;
  final double minimum, top, bottom;
  final List<ContainerBoxFrame> frames;
}

class ContainerFlowTail {
  const ContainerFlowTail(this.height, this.frames);

  final double height;
  final List<ContainerBoxFrame> frames;
}
