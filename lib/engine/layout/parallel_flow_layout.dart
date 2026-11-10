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
    bool floated(DisplayElement e) =>
        const {
          FloatSpec.left,
          FloatSpec.right,
        }.contains(styles[e.styleId ?? 0].block.float) &&
        e.firstBlock != null &&
        e.lastBlock != null &&
        styles[e.styleId ?? 0].size.width?.isAuto == false;
    for (final parent in source.elements) {
      var pending = <DisplayElement>[];
      void flush() {
        // 外层已接管的块不再建立重叠分组，避免嵌套浮动覆盖同一段正文。
        if (pending.length > 1 &&
            !pending.any((e) => members.contains(e.firstBlock))) {
          final group = List<DisplayElement>.of(pending);
          groups[group.first.firstBlock!] = group;
          for (final e in group) {
            for (var b = e.firstBlock!; b <= e.lastBlock!; b++) {
              members.add(b);
            }
          }
        }
        pending = [];
      }

      for (final child in parent.children) {
        final e = source.element(child)!;
        if (floated(e)) {
          // 块区间不能交叉，正文之间也不能凭相邻元素关系被吞掉。
          if (pending.isNotEmpty &&
              pending.last.lastBlock! + 1 != e.firstBlock) {
            flush();
          }
          pending.add(e);
        } else if (e.firstBlock != null) {
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

  List<MeasuredBlock> measure(int start, BlockMeasurer measurer) {
    final elements = groups[start]!;
    final placed = <Rect>[];
    final result = <MeasuredBlock>[];
    var currentY = 0.0;
    final id = '__parallel_${content.blocks[start].id}';
    for (final e in elements) {
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
      final geometry = DisplayBoxLayout.resolve(
        [chain[figureAt]],
        styles,
        options,
        available: parent.width,
      );
      final ctx = DisplayBoxLayout.context(computed, options, parent.width);
      final declared = computed.size.width!.resolve(ctx);
      // 默认 content-box：width 之外再加 padding/border；实际测量也用同一规则。
      final padding = geometry.chain.fold<double>(
        0,
        (n, f) => n + f.$2.insetLeft + f.$2.insetRight,
      );
      final margin = computed.block.margin;
      double px(Length? v) => v == null || v.isAuto ? 0 : v.resolve(ctx);
      final outer = math.min(
        parent.width,
        declared +
            (computed.size.boxSizing == BoxSizingSpec.borderBox ? 0 : padding) +
            px(margin?.left) +
            px(margin?.right),
      );
      final blocks = <MeasuredBlock>[];
      var height = 0.0;
      MeasuredBlock? previous;
      final tops = <double>[];
      for (var b = e.firstBlock!; b <= e.lastBlock!; b++) {
        final source = content.blocks[b];
        final measured = measurer.measure(
          source,
          withIndent:
              options.settings.indent &&
              (source.kind == BlockKind.paragraph ||
                  source.kind == BlockKind.quote),
        );
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
          (double y, r) => math.max(y, r.bottom),
        );
      }
      var x = 0.0;
      while (true) {
        final active = placed
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
          x = computed.block.float == FloatSpec.right
              ? fits.last.$2 - outer
              : fits.first.$1;
          break;
        }
        currentY = active.map((r) => r.bottom).reduce(math.min);
      }
      final bounds = Rect.fromLTWH(x, currentY, outer, height);
      placed.add(bounds);
      for (var i = 0; i < blocks.length; i++) {
        final block = blocks[i];
        result.add(
          block.inTable(
            id: id,
            bounds: bounds,
            top: currentY + tops[i],
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
    }
    return result;
  }
}
