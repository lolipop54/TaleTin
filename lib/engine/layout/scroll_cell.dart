part of 'scroll_chapter.dart';

/// 连续正文的一小段行。保留原块和偏移，不以临时行号保存阅读位置。
class ScrollCell {
  ScrollCell(
    this.block,
    this.measured,
    this.offset,
    this.from,
    this.to,
    this.gap, {
    this.endGap = 0,
    this.table = const [],
    this.tableHeight,
    this.containerTail = false,
  });
  final ContentBlock block;
  final MeasuredBlock measured;
  final int offset, from, to;
  final double gap;
  final double endGap;
  final List<PageFragment> table;
  final double? tableHeight;
  final bool containerTail;
  final pageImages = <PageFragment>[];
  ScrollCell withEndGap(double value) => ScrollCell(
    block,
    measured,
    offset,
    from,
    to,
    gap,
    endGap: value,
    table: table,
    tableHeight: tableHeight,
    containerTail: containerTail,
  )..pageImages.addAll(pageImages);
  // 负边距可以把绘制起点移到前一格，但列表仍需要非负的滚动占位。
  late final double flowExtent = (tableHeight ?? (gap + paintHeight)) + endGap;
  late final double height = math.max(0.0, flowExtent);

  late final double paintHeight =
      (from == 0 && measured.isText ? measured.bodyTop : 0) +
      (to == measured.lines.length && measured.isText
          ? measured.bodyBottom
          : 0) +
      (measured.isText
          ? measured.lines
                .sublist(from, to)
                .fold<double>(0, (n, l) => n + l.height)
          : measured.height) +
      (measured.isTitleDecoration && to == measured.lines.length
          ? kTitleRuleGap + kTitleRuleThickness
          : 0);

  /// 首批文字要跳过容器内边距；定位、选文与绘制共用这个起点。
  double get textTop => gap + (from == 0 ? measured.bodyTop : 0);

  /// 块级图片共用分页的居中和容器内边距；坐标相对当前滚动单元格。
  Iterable<({MeasuredBlock block, Rect rect})> positionedImages(
    double width,
  ) sync* {
    if (table.isNotEmpty) {
      for (final fragment in imagesInPaintOrder(table)) {
        final rect = fragment.imageRectIn(width);
        if (rect != null) yield (block: fragment.block, rect: rect);
      }
    } else {
      final rect = measured.imageRectIn(width, top: gap);
      if (rect != null) yield (block: measured, rect: rect);
    }
    for (final image in pageImages) {
      yield (block: image.block, rect: image.imageRectIn(width)!);
    }
  }

  /// 绘制和点按共用片段坐标，普通正文与表格内的公式走同一条路径。
  Iterable<({InlineImagePlacement image, Rect rect})>
  get positionedInlineImages sync* {
    if (table.isNotEmpty) {
      for (final fragment in table) {
        yield* fragment.positionedInlineImages;
      }
    } else {
      yield* PageFragment(
        block: measured,
        lineFrom: from,
        lineTo: to,
        y: gap,
        height: paintHeight,
      ).positionedInlineImages;
    }
  }

  int offsetAt(int line) =>
      offset + measured.lines[line].start - measured.displayPrefixLength;
}
