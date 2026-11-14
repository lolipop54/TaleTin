import 'dart:math' as math;

import 'package:flutter/painting.dart';

import '../../domain/models/book_document.dart';
import '../../domain/models/display_source_index.dart';
import '../styles/style_table.dart';
import '../styles/style_box_value.dart';
import '../styles/style_value.dart';
import 'block_measure.dart';
import 'display_box_layout.dart';
import 'display_tree.dart';
import 'layout_options.dart';
import 'measured_block.dart';

/// 相邻浮动图文块使用二维位置，文字仍保留原块号与偏移。
/// 分页、滚动借用现有二维分组的切片和定位，不转成图片或重建正文。
class ParallelFlowLayout {
  ParallelFlowLayout(this.content, this.tree, this.styles, this.options) {
    final source = tree.source;
    if (source == null) return;
    final tableBlocks = content.tables.expand((t) => t.blockIds).toSet();
    for (final parent in source.elements) {
      var pending = <DisplayElement>[];
      void flush() {
        if (pending.isNotEmpty) {
          final group = List<DisplayElement>.of(pending);
          groups.putIfAbsent(group.first.firstBlock!, () => group);
        }
        pending = [];
      }

      for (final child in parent.children) {
        final e = source.element(child)!;
        final start = e.firstBlock, end = e.lastBlock;
        if (start == null || end == null) continue;
        final computed = styles[e.styleId ?? 0];
        final floated =
            _side(e) != null &&
            computed.size.width?.isAuto == false &&
            !Iterable<int>.generate(
              end - start + 1,
              (i) => start + i,
            ).any((b) => tableBlocks.contains(content.blocks[b].id));
        // 普通段落和标题可以占图旁的剩余宽度。表格和复杂容器仍各自测量。
        final wraps =
            pending.isNotEmpty &&
            start == end &&
            !tableBlocks.contains(content.blocks[start].id) &&
            tree.emptyBefore(start).isEmpty &&
            const {'paragraph', 'heading'}.contains(e.role) &&
            computed.block.position != PositionSpec.absolute &&
            (computed.block.float == null ||
                computed.block.float == FloatSpec.none) &&
            (computed.block.clear == null ||
                computed.block.clear == ClearSpec.none) &&
            (content.blocks[start].kind == BlockKind.paragraph ||
                content.blocks[start].kind == BlockKind.heading);
        if (floated || wraps) {
          // 块区间不能交叉，正文之间也不能凭相邻元素关系被吞掉。
          if (pending.isNotEmpty &&
              (pending.last.lastBlock! + 1 != start ||
                  (floated && _side(pending.last) == null))) {
            flush();
          }
          if (floated || pending.isNotEmpty) pending.add(e);
        } else {
          flush();
        }
      }
      flush();
    }
  }
  final ChapterContent content;
  final DisplayTree tree;
  final StyleTable styles;
  final LayoutOptions options;
  final groups = <int, List<DisplayElement>>{};
  final members = <int>{};
  final ends = <int, int>{};

  bool? _side(DisplayElement element) =>
      switch (styles[element.styleId ?? 0].block.float) {
        FloatSpec.right || FloatSpec.inlineEnd => true,
        FloatSpec.left || FloatSpec.inlineStart => false,
        _ => null,
      };

  List<MeasuredBlock> measure(int start, BlockMeasurer measurer) {
    final elements = groups[start]!;
    final placed = <({Rect bounds, bool right})>[];
    final result = <MeasuredBlock>[];
    var currentY = 0.0;
    var flowY = 0.0;
    MeasuredBlock? lastProse;
    final id = '__parallel_${content.blocks[start].id}';
    for (final e in elements) {
      final rightSide = _side(e);
      final chain = [...tree.chainOf(e.firstBlock!)];
      var figureAt = chain.indexWhere((c) => c.elementId == e.id);
      if (figureAt < 0) {
        figureAt = chain.length;
        chain.add(
          DisplayContainer(
            elementId: e.id,
            styleId: e.styleId ?? 0,
            first: true,
            last: true,
            role: e.role,
            tag: e.tag,
          ),
        );
      }
      final ancestors = chain.take(figureAt).toList();
      final parent = DisplayBoxLayout.resolve(ancestors, styles, options);
      final computed = styles[e.styleId ?? 0];
      if (rightSide == null) {
        final source = content.blocks[e.firstBlock!];
        final natural = _measure(measurer, source);
        final top =
            flowY +
            (lastProse == null ? 0 : measurer.gapBefore(lastProse, natural));
        final active = placed.where((r) => r.bounds.bottom > top + .1);
        if (active.isEmpty) break;
        final left = active
            .where((r) => !r.right)
            .fold(0.0, (edge, r) => math.max(edge, r.bounds.right));
        final right = active
            .where((r) => r.right)
            .fold(parent.width, (edge, r) => math.min(edge, r.bounds.left));
        // 剩余空间太窄时让段落排在图下，避免把文字压成一字一行。
        if (right - left <
            options.textScaler.scale(options.settings.fontSize.toDouble()) *
                4) {
          break;
        }
        final constrained = BlockMeasurer(
          options,
          styleTable: styles,
          displayTree: tree,
          floatInsets: (
            parentId: e.parent!,
            left: left,
            right: parent.width - right,
          ),
        );
        final bottom = active.fold(0.0, (y, r) => math.max(y, r.bounds.bottom));
        final measured = constrained.wrapBesideFloat(
          source,
          measurer,
          bottom - top,
          withIndent:
              options.settings.indent && source.kind == BlockKind.paragraph,
        );
        result.add(
          measured.inTable(
            id: id,
            bounds: Rect.fromLTWH(
              parent.left + left,
              top,
              right - left,
              measured.height,
            ),
            top: top,
            unit: 1,
            header: true,
            width: measured.layoutWidth!,
            containerBoxes: measured.containerBoxes,
            horizontalShift: 0,
          ),
        );
        lastProse = measured;
        flowY = top + measured.height;
        members.add(e.firstBlock!);
        ends[start] = e.lastBlock!;
        continue;
      }
      final geometry = DisplayBoxLayout.resolve(
        [chain[figureAt]],
        styles,
        options,
        available: parent.width,
      );
      final ctx = DisplayBoxLayout.context(computed, options, parent.width);
      final margin = computed.block.margin;
      double px(Length? v) =>
          v == null || v.isAuto ? 0 : math.max(0, v.resolve(ctx));
      final outer = math.min(
        parent.width,
        geometry.width +
            geometry.chain.fold<double>(
              0,
              (n, f) => n + f.$2.insetLeft + f.$2.insetRight,
            ) +
            px(margin?.left) +
            px(margin?.right),
      );
      final blocks = <MeasuredBlock>[];
      var height = 0.0;
      MeasuredBlock? previous;
      final tops = <double>[];
      for (var b = e.firstBlock!; b <= e.lastBlock!; b++) {
        final source = content.blocks[b];
        final measured = _measure(measurer, source);
        if (previous != null) height += measurer.gapBefore(previous, measured);
        tops.add(height);
        blocks.add(measured);
        height += measured.height;
        previous = measured;
      }
      // 浏览器式浮动：优先使用当前高度的剩余横向空间；放不下时移动到
      // 最近浮动块的底边。各图注按真实高度占位，不采用书里过小的固定高度裁字。
      if (computed.block.clear != null &&
          computed.block.clear != ClearSpec.none) {
        currentY = placed.fold(
          currentY,
          (double y, r) => math.max(y, r.bounds.bottom),
        );
      }
      var x = 0.0;
      while (true) {
        final active = placed
            .map((r) => r.bounds)
            .where((r) => r.top <= currentY + .1 && r.bottom > currentY + .1)
            .toList();
        final intervals = <(double, double)>[(0, parent.width)];
        for (final r in active) {
          final next = <(double, double)>[];
          for (final interval in intervals) {
            if (r.right <= interval.$1 || r.left >= interval.$2) {
              next.add(interval);
              continue;
            }
            if (r.left > interval.$1) next.add((interval.$1, r.left));
            if (r.right < interval.$2) next.add((r.right, interval.$2));
          }
          intervals
            ..clear()
            ..addAll(next);
        }
        final fits = intervals.where((r) => r.$2 - r.$1 >= outer - .1).toList();
        if (fits.isNotEmpty) {
          x = rightSide ? fits.last.$2 - outer : fits.first.$1;
          break;
        }
        currentY = active.map((r) => r.bottom).reduce(math.min);
      }
      final contentTop = currentY + px(margin?.top);
      final bounds = Rect.fromLTWH(
        x,
        currentY,
        outer,
        height + px(margin?.top) + px(margin?.bottom),
      );
      placed.add((bounds: bounds, right: rightSide));
      for (var i = 0; i < blocks.length; i++) {
        final block = blocks[i];
        result.add(
          block.inTable(
            id: id,
            bounds: bounds.shift(Offset(parent.left, 0)),
            top: contentTop + tops[i],
            horizontalShift: x,
            unit: 1,
            header: true,
            width: block.layoutWidth ?? geometry.width,
            containerBoxes: [
              for (final f in block.containerBoxes)
                ContainerBoxFrame(
                  elementId: f.elementId,
                  box: f.box,
                  first: f.first,
                  last: f.last,
                  left: f.left + x,
                  width: f.width,
                  top: f.top,
                  bottom: f.bottom,
                  lineFrom: f.lineFrom,
                  lineTo: f.lineTo,
                ),
            ],
          ),
        );
      }
      members.addAll(
        Iterable<int>.generate(
          e.lastBlock! - e.firstBlock! + 1,
          (i) => e.firstBlock! + i,
        ),
      );
      ends[start] = e.lastBlock!;
    }
    return result;
  }

  MeasuredBlock _measure(BlockMeasurer measurer, ContentBlock block) =>
      measurer.measure(
        block,
        withIndent:
            options.settings.indent &&
            (block.kind == BlockKind.paragraph ||
                block.kind == BlockKind.quote),
      );
}
