import 'dart:math' as math;

import 'package:flutter/painting.dart';

import '../../domain/models/book_document.dart';
import '../../domain/models/display_source_index.dart';
import '../styles/style_table.dart';
import '../styles/style_box_value.dart';
import '../styles/style_value.dart';
import 'block_measure.dart';
import 'compact_image_policy.dart';
import 'display_box_layout.dart';
import 'display_position.dart';
import 'box_size_resolver.dart';
import 'resolve_block_box.dart';
import 'display_tree.dart';
import 'float_line_space.dart';
import 'table_layout.dart' show measureTable, tableHeight;
import 'layout_options.dart';
import 'measured_block.dart';
import 'vertical_margins.dart';

part 'compact_float_layout.dart';

/// 相邻浮动图文块使用二维位置，文字仍保留原块号与偏移。
/// 分页、滚动借用现有二维分组的切片和定位，不转成图片或重建正文。
class ParallelFlowLayout {
  ParallelFlowLayout(this.content, this.tree, this.styles, this.options) {
    final source = tree.source;
    if (source == null) return;
    final tableBlocks = {
      ...content.tables.expand((t) => t.blockIds),
      ...tree.captionBlockIds,
    };
    for (final parent in source.elements) {
      DisplayElement? previousImage;
      for (final id in parent.children) {
        final child = source.element(id)!;
        final index = child.firstBlock;
        final style = styles[child.styleId ?? 0];
        final singleImage =
            index != null &&
            child.lastBlock == index &&
            content.blocks[index].kind == BlockKind.image &&
            !tableBlocks.contains(content.blocks[index].id) &&
            !tree.hiddenBlocks.contains(index) &&
            style.block.position != PositionSpec.absolute &&
            (style.block.float == null || style.block.float == FloatSpec.none);
        if (!singleImage) {
          previousImage = null;
          continue;
        }
        final margin = style.block.margin?.top;
        final previous = previousImage?.firstBlock;
        if (previous != null &&
            previous + 1 == index &&
            margin != null &&
            !margin.isAuto &&
            margin.resolve(
                  DisplayBoxLayout.context(
                    style,
                    options,
                    options.contentWidth,
                  ),
                ) <
                0 &&
            !groups.containsKey(previous)) {
          // 两个相邻的单图盒子可通过负上外边距叠放，例如封面压在书架上。
          // 把它们交给同一组绘制，分页与滚动才能留下相同的可见重叠部分。
          groups[previous] = [previousImage!, child];
          _overlappingImages.add(previous);
          previousImage = null;
        } else {
          previousImage = child;
        }
      }
      final first = parent.firstBlock, last = parent.lastBlock;
      if (first != null &&
          last != null &&
          first < last &&
          styles[parent.styleId ?? 0].block.position == PositionSpec.relative) {
        final images = <int, DisplayElement>{};
        void collect(DisplayElement e) {
          final position = styles[e.styleId ?? 0].block.position;
          if (position == PositionSpec.absolute) {
            final i = e.firstBlock;
            if (i != null &&
                i == e.lastBlock &&
                !tree.hiddenBlocks.contains(i) &&
                content.blocks[i].kind == BlockKind.image) {
              images[i] = e;
            }
          } else if (position == null || position == PositionSpec.static) {
            for (final id in e.children) {
              collect(source.element(id)!);
            }
          }
        }

        for (final id in parent.children) {
          collect(source.element(id)!);
        }
        if (images.isNotEmpty &&
            tree.chainOf(first).any((c) => c.elementId == parent.id) &&
            Iterable<int>.generate(last - first + 1, (i) => first + i).any(
              (i) => !images.containsKey(i) && !tree.hiddenBlocks.contains(i),
            ) &&
            !content.blocks
                .getRange(first, last + 1)
                .any((b) => tableBlocks.contains(b.id))) {
          _relativeImages[first] = (parent, images);
          groups[first] = images.values.toList();
        }
      }
      var pending = <DisplayElement>[];
      void flush() {
        if (pending.isNotEmpty) {
          final group = List<DisplayElement>.of(pending);
          groups.putIfAbsent(group.first.firstBlock!, () => group);
        }
        pending = [];
      }

      // 普通 div 不建立新的浮动上下文。连续浮动从上一层延入该容器时，
      // 诗句和标题仍共享同一排可用宽度；clear 在原来的位置结束这一排。
      Iterable<DisplayElement> children() sync* {
        for (final child in parent.children) {
          final e = source.element(child)!;
          final s = styles[e.styleId ?? 0];
          if (pending.isNotEmpty &&
              e.tag == 'div' &&
              _side(e) == null &&
              (s.box.isEmpty ||
                  (s.box.padding == Edges.zero &&
                      s.box.border == null &&
                      s.box.background == null &&
                      s.box.shadow == null &&
                      s.box.overflow == null)) &&
              !s.size.hasDimensions &&
              (s.block.margin == null || s.block.margin == Edges.zero) &&
              (s.block.position == null ||
                  s.block.position == PositionSpec.static) &&
              (s.block.clear == null || s.block.clear == ClearSpec.none) &&
              (s.block.display == null ||
                  s.block.display == DisplaySpec.block) &&
              e.children.isNotEmpty &&
              e.firstBlock != null &&
              e.lastBlock != null) {
            final inner = [for (final id in e.children) source.element(id)!];
            final columns = inner.where((n) => n.firstBlock != null);
            if (columns.isNotEmpty &&
                columns.first.firstBlock == e.firstBlock &&
                columns.last.lastBlock == e.lastBlock &&
                columns.every((n) => _side(n) != null)) {
              yield* inner;
              continue;
            }
          }
          yield e;
        }
      }

      for (final e in children()) {
        final computed = styles[e.styleId ?? 0];
        if (computed.block.clear != null &&
            computed.block.clear != ClearSpec.none) {
          flush();
        }
        final start = e.firstBlock, end = e.lastBlock;
        if (start == null || end == null || tree.hiddenBlocks.contains(start)) {
          continue;
        }
        final floated =
            _side(e) != null &&
            (e.tag != 'img' ||
                (content.blocks[start].kind == BlockKind.image &&
                    source.ownerOfBlock(start)?.id == e.id)) &&
            (e.tag == "table" && e.table != null ||
                (start == end &&
                    content.blocks[start].kind == BlockKind.image) ||
                computed.size.width?.isAuto == false) &&
            (e.tag == "table" ||
                !Iterable<int>.generate(
                  end - start + 1,
                  (i) => start + i,
                ).any((b) => tableBlocks.contains(content.blocks[b].id)));
        // 图旁的段落常被一个 div 包起来，例如人物名称、简介、武器三段。
        // 逐段沿用同一个浮动范围，容器本身仍保留在段落的样式链里。
        final prose = pending.isEmpty || floated
            ? const <DisplayElement>[]
            : _proseOf(e, tableBlocks);
        if (floated || prose.isNotEmpty) {
          if (floated &&
              (e.tag == 'table' || pending.firstOrNull?.tag == 'table')) {
            flush();
          }
          // 块区间不能交叉，正文之间也不能凭相邻元素关系被吞掉。
          if (pending.isNotEmpty &&
              (pending.last.lastBlock! + 1 != start ||
                  (floated && _side(pending.last) == null))) {
            flush();
          }
          if (floated) {
            pending.add(e);
          } else if (pending.isNotEmpty) {
            pending.addAll(prose);
          }
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
  final _relativeImages = <int, (DisplayElement, Map<int, DisplayElement>)>{};
  final _overlappingImages = <int>{};

  List<DisplayElement> _proseOf(
    DisplayElement element,
    Set<String> tableBlocks,
  ) {
    final style = styles[element.styleId ?? 0].block;
    if (style.position == PositionSpec.absolute ||
        _side(element) != null ||
        (style.clear != null && style.clear != ClearSpec.none)) {
      return const [];
    }
    final start = element.firstBlock, end = element.lastBlock;
    if (start == null || end == null || tree.hiddenBlocks.contains(start)) {
      return const [];
    }
    if (start == end &&
        (const {'paragraph', 'heading'}.contains(element.role) ||
            (element.tag == 'div' &&
                tree.source!.ownerOfBlock(start)?.id == element.id)) &&
        !tableBlocks.contains(content.blocks[start].id) &&
        tree.emptyBefore(start).isEmpty &&
        (content.blocks[start].kind == BlockKind.paragraph ||
            content.blocks[start].kind == BlockKind.heading)) {
      return [element];
    }
    if (element.tag != 'div') return const [];
    final source = tree.source!;
    final children = [
      for (final id in element.children)
        if (source.element(id)!.firstBlock != null) source.element(id)!,
    ];
    final parts = [
      for (final child in children) ..._proseOf(child, tableBlocks),
    ];
    // 包装层有图片、表格或直接文字时不能跨过去吞掉其位置。
    if (parts.length != end - start + 1 ||
        parts.indexed.any((part) => part.$2.firstBlock != start + part.$1)) {
      return const [];
    }
    return parts;
  }

  bool? _side(DisplayElement element) =>
      switch (styles[element.styleId ?? 0].block.float) {
        FloatSpec.right || FloatSpec.inlineEnd => true,
        FloatSpec.left || FloatSpec.inlineStart => false,
        _ => null,
      };

  List<MeasuredBlock> measure(int start, BlockMeasurer sourceMeasurer) =>
      _measureGroup(start, sourceMeasurer);

  List<MeasuredBlock> _measureGroup(
    int start,
    BlockMeasurer sourceMeasurer, {
    double? firstTop,
    List<MeasuredBlock>? original,
    Map<String, double>? captionStarts,
  }) {
    // 这组块会在独立坐标内重新排，祖先留白由组内位置计算。
    final measurer = sourceMeasurer.withOptions(options, normalFlow: false);
    if (_overlappingImages.contains(start)) {
      return _measureOverlappingImages(start, measurer);
    }
    if (_relativeImages[start] case (final parent, final child)) {
      return _measureRelativeImage(start, parent, child, measurer);
    }
    final elements = groups[start]!;
    final through = original == null
        ? null
        : tree.blockIndexById[original.last.blockId];
    var resized = false;
    void recordElement(DisplayElement element) {
      // 试排使用原来已经量过的块，不能改变后续分页读取正文的范围。
      if (original != null) return;
      final last = element.lastBlock!;
      for (var i = element.firstBlock!; i <= last; i++) {
        members.add(i);
      }
      ends[start] = last;
    }

    final placed = <FloatFootprint>[];
    final result = <MeasuredBlock>[];
    var currentY = 0.0;
    double? firstNegativeMargin;
    var flowY = 0.0;
    MeasuredBlock? lastProse;
    var id = '__parallel_${content.blocks[start].id}';
    final parentId = elements.first.parent!;
    for (final e in elements) {
      if (through != null && e.firstBlock! > through) break;
      final rightSide = _side(e);
      final chain = [...tree.chainOf(e.firstBlock!)];
      var wrapper = e;
      while (rightSide == null &&
          wrapper.parent != null &&
          wrapper.parent != parentId) {
        wrapper = tree.source!.element(wrapper.parent!)!;
      }
      var figureAt = chain.indexWhere((c) => c.elementId == wrapper.id);
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
      final parent = DisplayBoxLayout.resolve(
        ancestors,
        styles,
        options,
        tree: tree,
      );
      final computed = styles[e.styleId ?? 0];
      if (e.tag == 'table' && rightSide != null) {
        final index = e.table;
        final table = index != null && index < content.tables.length
            ? content.tables[index]
            : null;
        if (table == null) {
          ends[start] = e.lastBlock!;
          return [];
        }
        final grid = measureTable(
          table,
          {for (final b in content.blocks) b.id: b},
          options,
          styleTable: styles,
          displayTree: tree,
          order: content.blocks,
        );
        if (grid.isEmpty) {
          ends[start] = e.lastBlock!;
          return [];
        }
        result.addAll(grid);
        id = grid.first.tableId!;
        final left =
            grid.map((b) => b.tableBounds!.left).reduce(math.min) - parent.left;
        final right =
            grid.map((b) => b.tableBounds!.right).reduce(math.max) -
            parent.left;
        placed.add((
          right: rightSide,
          bounds: Rect.fromLTRB(left, 0, right, tableHeight(grid)),
        ));
        recordElement(e);
        continue;
      }
      if (rightSide == null) {
        if (original != null && !resized) return original;
        final source = content.blocks[e.firstBlock!];
        final natural = _measure(measurer, source);
        final paragraphTop =
            flowY +
            (lastProse == null ? 0 : measurer.gapBefore(lastProse, natural));
        // 试排沿用已交付的块范围。缩图后已越过图底的段落在这里恢复整宽。
        if (through == null &&
            !placed.any((r) => r.bounds.bottom > paragraphTop + .001)) {
          break;
        }
        final (measured, top, left, right) = measurer.wrapBesideFloats(
          source,
          natural,
          placed,
          parentLeft: parent.left,
          parentWidth: parent.width,
          paragraphTop: paragraphTop,
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
            authorStyle: elements.first.tag == "table",
            unit: elements.first.tag == "table" ? 0 : 1,
            header: true,
            width: measured.layoutWidth!,
            containerBoxes: measured.containerBoxes,
            horizontalShift: 0,
          ),
        );
        lastProse = measured;
        flowY = top + measured.height;
        recordElement(e);
        continue;
      }
      final geometry = DisplayBoxLayout.resolve(
        [chain[figureAt]],
        styles,
        options,
        tree: tree,
        available: parent.width,
      );
      final ctx = DisplayBoxLayout.context(computed, options, parent.width);
      // 未写宽度的单图浮动框按图本身的显示宽度占位。
      final figureWidth =
          computed.size.width?.isAuto != false &&
              e.firstBlock == e.lastBlock &&
              content.blocks[e.firstBlock!].kind == BlockKind.image
          ? _measure(measurer, content.blocks[e.firstBlock!]).imageSize!.width
          : geometry.width;
      final margin = computed.block.margin;
      double px(Length? v) =>
          v == null || v.isAuto ? 0 : math.max(0, v.resolve(ctx));
      final horizontalSpace =
          geometry.chain.fold<double>(
            0,
            (n, f) => n + f.$2.insetLeft + f.$2.insetRight,
          ) +
          px(margin?.left) +
          px(margin?.right);
      if (computed.block.clear != null &&
          computed.block.clear != ClearSpec.none) {
        currentY = placed.fold(
          currentY,
          (double y, r) => math.max(y, r.bounds.bottom),
        );
      }
      final topMargin = margin?.top;
      final signedTop = topMargin == null || topMargin.isAuto
          ? 0.0
          : topMargin.resolve(ctx);
      firstNegativeMargin ??= math.min(0.0, signedTop);
      // 组首的负边距已计入外部段距；各列按自己的上边距保留相对高差。
      final topInset = math.max(0.0, signedTop - firstNegativeMargin);
      final column = _placeColumn(
        e,
        measurer,
        placed,
        parentWidth: parent.width,
        width: figureWidth,
        horizontalSpace: horizontalSpace,
        verticalSpace: topInset + px(margin?.bottom),
        topInset: topInset,
        rightSide: rightSide,
        startY: currentY,
        firstTop: firstTop,
      );
      final (blocks, tops, _) = column.content;
      final bounds = column.bounds;
      currentY = bounds.top;
      final x = bounds.left;
      final contentTop = currentY + topInset;
      if (column.keepHeight case final keep?) {
        captionStarts![blocks.first.blockId] = currentY + keep;
      }
      resized |= column.scale < 1;
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
            width: e.tag == 'img'
                ? block.imageSize!.width
                : block.layoutWidth ?? geometry.width,
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
      recordElement(e);
    }
    // 纸面首列上方没有可借用的前一段空白。整组从正文上沿开始，
    // 保留组内高差，避免大字号时把标题的第一个字推出屏幕。
    if (start == 0 && result.first.leadingMargin.extent < 0) {
      final first = result.first;
      result[0] = first.withBoxEdges(
        first: first.boxFirst,
        last: first.boxLast,
        flowMargins: BlockMargins(
          const VerticalMargin.zero(),
          first.trailingMargin,
        ),
      );
    }
    return !resized && original != null ? original : result;
  }

  List<MeasuredBlock> _measureOverlappingImages(
    int start,
    BlockMeasurer measurer,
  ) {
    final first = _measure(measurer, content.blocks[start]);
    final second = _measure(measurer, content.blocks[start + 1]);
    final id = '__parallel_${first.blockId}';
    MeasuredBlock place(
      MeasuredBlock block,
      double top,
      double tail,
      double descent,
    ) {
      final image = block.imageRectIn(options.contentWidth)!;
      final outerTop = block.box?.insetTop ?? 0.0;
      final height = outerTop + image.height + tail + descent;
      final leading = block.bodyTop - outerTop;
      final trailing = block.bodyBottom - tail;
      return block
          .withBoxEdges(
            first: block.boxFirst,
            last: block.boxLast,
            height: height,
            bodyTop: outerTop,
            bodyBottom: tail + descent,
          )
          .inTable(
            id: id,
            bounds: Rect.fromLTWH(image.left, top, image.width, height),
            top: top,
            unit: 1,
            header: true,
            width: block.layoutWidth ?? image.width,
            horizontalShift: 0,
            containerBoxes: [
              for (final frame in block.containerBoxes)
                ContainerBoxFrame(
                  elementId: frame.elementId,
                  box: frame.box,
                  first: frame.first,
                  last: frame.last,
                  left: frame.left,
                  width: frame.width,
                  top: frame.top - leading,
                  bottom: frame.bottom - trailing,
                  height: frame.height,
                  lineFrom: frame.lineFrom,
                  lineTo: frame.lineTo,
                ),
            ],
          );
    }

    members.addAll([start, start + 1]);
    ends[start] = start + 1;
    final firstTop = first.bodyTop - (first.box?.insetTop ?? 0);
    final firstDescent = measurer.imageBaselineTail(start);
    final secondDescent = measurer.imageBaselineTail(start + 1);
    final secondTop =
        first.height +
        firstDescent +
        second.bodyTop -
        (second.box?.insetTop ?? 0);
    // 负外边距可能让后画的图越过组的顶部。两张图一起移进可用区域，
    // 保留原有的相对位置，避免单独挪封面时让它压住书架的前沿。
    final shift = math.max(0.0, -math.min(firstTop, secondTop));
    return [
      place(
        first,
        firstTop + shift,
        first.box?.insetBottom ?? 0.0,
        firstDescent,
      ),
      place(second, secondTop + shift, second.bodyBottom, secondDescent),
    ];
  }

  /// 先排正文得到父框实际高度，再把装饰图放回原顺序。
  /// 图片出现在源码中的先后不应改变段落位置。
  List<MeasuredBlock> _measureRelativeImage(
    int start,
    DisplayElement parent,
    Map<int, DisplayElement> images,
    BlockMeasurer measurer,
  ) {
    final id = '__parallel_${content.blocks[start].id}';
    final last = parent.lastBlock!;
    final source = tree.source!;
    final group = <int, MeasuredBlock>{};
    final chain = tree.chainOf(start);
    final parentIndex = chain.indexWhere((e) => e.elementId == parent.id);
    final geometry = DisplayBoxLayout.resolve(
      chain.take(parentIndex + 1).toList(),
      styles,
      options,
      tree: tree,
    );
    final frame = geometry.frames
        .where((f) => f.elementId == parent.id)
        .firstOrNull;
    final box = frame?.box;
    final flow = BlockMeasurer(
      options,
      styleTable: styles,
      displayTree: tree,
      normalFlow: false,
      outOfFlow: images.keys.toSet(),
    );
    double y = 0;
    MeasuredBlock? previous;
    for (var i = start; i <= last; i++) {
      if (images.containsKey(i) || tree.hiddenBlocks.contains(i)) continue;
      final measured = _measure(flow, content.blocks[i]);
      if (previous != null) y += flow.gapBefore(previous, measured);
      final width = measured.layoutWidth ?? options.contentWidth;
      group[i] = measured.inTable(
        id: id,
        bounds: Rect.fromLTWH(measured.inset, y, width, measured.height),
        top: y,
        unit: 1,
        header: true,
        width: width,
        horizontalShift: 0,
        containerBoxes: measured.containerBoxes,
      );
      y += measured.height;
      previous = measured;
    }
    final left = geometry.left - (box?.padLeft ?? 0);
    final top = geometry.top - (box?.padTop ?? 0);
    final w = geometry.width + (box?.padLeft ?? 0) + (box?.padRight ?? 0);
    final tail = previous!.containerBoxes
        .where((f) => f.elementId == parent.id)
        .firstOrNull;
    final h = geometry.containerHeight == null
        ? math.max(
            0.0,
            y - top - (tail?.bottom ?? 0) - (box?.borderBottom ?? 0),
          )
        : geometry.containerHeight! +
              (box?.padTop ?? 0) +
              (box?.padBottom ?? 0);
    for (final entry in images.entries) {
      final i = entry.key, wrapper = entry.value, block = content.blocks[i];
      final style = styles[wrapper.styleId ?? 0];
      final ctx = DisplayBoxLayout.context(style, options, w);
      final owner = source.ownerOfBlock(i)!;
      final imgStyle = styles[owner.styleId ?? 0];
      final wrapped = owner.id != wrapper.id;
      final inner = wrapped
          ? DisplayBoxLayout.resolve(
              tree
                  .chainOf(i)
                  .skipWhile((e) => e.elementId != wrapper.id)
                  .toList(),
              styles,
              options,
              tree: tree,
              available: w,
              availableHeight: h,
            )
          : null;
      final available = inner?.width ?? w;
      final original = _measure(measurer, block);
      final size = measurer.imageSizeIn(
        block,
        imgStyle,
        DisplayBoxLayout.context(imgStyle, options, available),
        original.box,
        available,
        options.contentHeight,
        wrapped ? inner?.containerHeight : h,
      );
      // right/bottom 的偏移量扣边框盒，盒内的图片则按内容区对齐。
      final wrapperBox = wrapped
          ? resolveBlockBox(style.box, ctx)
          : original.box;
      final sizes = BoxSizeResolver(
        ctx,
        style.size,
        wrapperBox,
        parentHeight: h,
      );
      final contentW = wrapped ? sizes.width.use(size.width) : size.width;
      final contentH = wrapped ? sizes.height.use(size.height) : size.height;
      final wrapperWidth =
          contentW +
          (wrapperBox?.insetLeft ?? 0) +
          (wrapperBox?.insetRight ?? 0);
      final wrapperHeight =
          contentH +
          (wrapperBox?.insetTop ?? 0) +
          (wrapperBox?.insetBottom ?? 0);
      final x = DisplayPosition.offset(
        style,
        options,
        w,
        h,
        wrapperWidth,
        vertical: false,
      );
      final dy = DisplayPosition.offset(
        style,
        options,
        w,
        h,
        wrapperHeight,
        vertical: true,
      );
      final aligned = switch (original.align) {
        'right' => contentW - size.width,
        'center' => (wrapperWidth - size.width) / 2,
        _ => 0.0,
      };
      final rect =
          Offset(
            (x == null ? geometry.left : left + x) +
                aligned +
                (wrapperBox?.insetLeft ?? 0),
            dy == null
                ? (group.entries
                          .where((e) => e.key < i && !images.containsKey(e.key))
                          .lastOrNull
                          ?.value
                          .tableBounds
                          ?.bottom ??
                      geometry.top)
                : top + dy + (wrapperBox?.insetTop ?? 0),
          ) &
          size;
      group[i] = original
          .withBoxEdges(
            first: original.boxFirst,
            last: original.boxLast,
            imageSize: size,
            height: size.height,
            bodyTop: 0,
            bodyBottom: 0,
          )
          .inTable(
            id: id,
            bounds: rect,
            top: rect.top,
            unit: 1,
            header: true,
            width: size.width,
            cellInset: 0,
            positionedOverlay: true,
          );
    }
    ends[start] = last;
    members.addAll(Iterable<int>.generate(last - start + 1, (i) => start + i));
    return [for (var i = start; i <= last; i++) ?group[i]];
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
