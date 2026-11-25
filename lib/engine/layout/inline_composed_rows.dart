part of 'block_measure.dart';

extension _InlineComposedRows on BlockMeasurer {
  List<DisplayNode> _inlineCandidates(ContentBlock block) {
    final tree = displayTree;
    return tree?.inlineLayoutCandidates[tree.blockIndexById[block.id]] ??
        const [];
  }

  bool _isSizedInlineBox(DisplayNode node) =>
      node.display == DisplaySpec.inlineBlock &&
      styleTable?[node.element.styleId ?? 0].size.width?.isAuto == false;

  ({int start, int end})? _textRange(DisplayNode node, int index) {
    int? start, end;
    for (final range in node.element.ranges) {
      if (range.block != index || range.start >= range.end) continue;
      start = math.min(start ?? range.start, range.start);
      end = math.max(end ?? range.end, range.end);
    }
    return start == null || end == null ? null : (start: start, end: end);
  }

  ({int end, MeasuredSegment glyph, double width, double height})?
  _leadingFloat(
    ContentBlock block,
    List<TextRun> runs,
    List<TextStyle> styles,
    String text,
    double width,
  ) {
    final index = displayTree!.blockIndexById[block.id]!;
    for (final node in _inlineCandidates(block)) {
      final style = styleTable![node.element.styleId ?? 0];
      if (style.block.float != FloatSpec.left || !style.box.isEmpty) continue;
      final range = _textRange(node, index);
      if (range == null ||
          range.start != 0 ||
          range.end >= text.length ||
          text.substring(0, range.end).contains('\n')) {
        continue;
      }
      final painter = TextPainter(
        text: TextSpan(
          children: BlockMeasurer._slice(runs, styles, 0, range.end),
        ),
        textDirection: TextDirection.ltr,
        textScaler: options.textScaler,
      )..layout();
      final metrics = painter.computeLineMetrics().first;
      painter.dispose();
      final context = _lengthContext(style, width);
      double pad(Length? length) => length == null || length.isAuto
          ? 0
          : math.max(0, length.resolve(context));
      final left = pad(style.block.margin?.left);
      final totalWidth = left + metrics.width + pad(style.block.margin?.right);
      if (totalWidth > width * .6) return null;
      return (
        end: range.end,
        glyph: MeasuredSegment(
          start: 0,
          end: range.end,
          left: left,
          width: metrics.width,
          top: pad(style.block.margin?.top),
          baseline: metrics.baseline,
        ),
        width: totalWidth,
        height:
            metrics.height +
            pad(style.block.margin?.top) +
            pad(style.block.margin?.bottom),
      );
    }
    return null;
  }

  /// 定宽行内盒内部可以按自己的宽度换行。整排一起分页，文字照常可选取。
  MeasuredLine? _measureInlineColumns(
    ContentBlock block,
    List<TextRun> runs,
    List<TextStyle> styles,
    String text,
    double width,
    Set<int> boundaries,
    double? parentHeight,
  ) {
    final index = displayTree!.blockIndexById[block.id]!;
    final candidates = _inlineCandidates(block)
        .where(_isSizedInlineBox)
        .toList();
    if (candidates.length < 2 ||
        candidates.any(
          (node) => node.element.parent != candidates.first.element.parent,
        )) {
      return null;
    }
    // 有真实装饰的行内盒继续交给逐行测量，保留它的边框、底色和内边距。
    for (final span in block.inlineBoxes) {
      final id = span.styleId;
      if (id == null) return null;
      final computed = styleTable![id];
      final box = resolveBlockBox(
        computed.box,
        _lengthContext(computed, width),
      );
      if (box != null &&
          ((box.background?.a ?? 0) > 0 ||
              box.backgroundImage != null ||
              box.shadows.isNotEmpty ||
              box.insetLeft + box.insetRight + box.insetTop + box.insetBottom >
                  0)) {
        return null;
      }
    }
    final columns =
        <({List<MeasuredSegment> segments, double height, String? valign})>[];
    final widths = <DisplayNode, ({BoxSizeResolver size, EdgeInsets margin})>{};
    var declaredWidth = 0.0;
    for (final node in candidates) {
      final style = styleTable![node.element.styleId ?? 0];
      final ctx = _lengthContext(style, width);
      final size = BoxSizeResolver(
        ctx,
        style.size,
        resolveBlockBox(style.box, ctx),
        parentHeight: parentHeight,
      );
      final margins = style.block.margin?.resolve(ctx);
      final margin = EdgeInsets.fromLTRB(
        margins?.left ?? 0,
        margins?.top ?? 0,
        margins?.right ?? 0,
        margins?.bottom ?? 0,
      );
      widths[node] = (size: size, margin: margin);
      declaredWidth += size.width.definite! + margin.horizontal;
    }
    if (declaredWidth > width + .01) return null;
    // 统一阅读字体后，普通空格可能比作者原字体更宽。压缩列间的源码空白，
    // 让原本加起来未超过整行的行内盒保持并排，仍使用作者写的列宽。
    final maxGap =
        math.max(0.0, width - declaredWidth) / (candidates.length - 1);
    var x = 0.0, rowHeight = 0.0, previousEnd = 0;
    for (final node in candidates) {
      final range = _textRange(node, index);
      if (range == null ||
          range.start < previousEnd ||
          text.substring(previousEnd, range.start).trim().isNotEmpty) {
        return null;
      }
      final style = styleTable![node.element.styleId ?? 0];
      final column = widths[node]!;
      final columnWidth = column.size.width.definite!;
      final gap = range.start > previousEnd && columns.isNotEmpty
          ? math.min(_spaceWidth(styles.first), maxGap)
          : 0.0;
      x += gap + column.margin.left;
      if (columnWidth <= 0 || x + columnWidth > width + .01) return null;
      final cuts = <int>{
        range.start,
        range.end,
        for (final point in boundaries)
          if (point > range.start && point < range.end) point,
      }.toList()..sort();
      final segments = <MeasuredSegment>[];
      var y = column.margin.top;
      for (var i = 0; i + 1 < cuts.length; i++) {
        var start = cuts[i], end = cuts[i + 1];
        // 标签之间的排版空白不应单独撑开一个行带。
        while (start < end && text[start].trim().isEmpty) {
          start++;
        }
        while (end > start && text[end - 1].trim().isEmpty) {
          end--;
        }
        if (start == end) continue;
        final owner = displayTree!.flows[index]
            ?.where(
              (child) => child.element.ranges.any(
                (r) => r.block == index && r.start <= start && r.end >= end,
              ),
            )
            .lastOrNull;
        final align =
            styleTable![owner?.element.styleId ?? node.element.styleId ?? 0]
                .block
                .textAlign;
        final painter = TextPainter(
          text: TextSpan(
            children: BlockMeasurer._slice(runs, styles, start, end),
          ),
          textAlign: switch (align) {
            TextAlignSpec.center => TextAlign.center,
            TextAlignSpec.right => TextAlign.right,
            _ => TextAlign.left,
          },
          textDirection: TextDirection.ltr,
          textScaler: options.textScaler,
        )..layout(minWidth: columnWidth, maxWidth: columnWidth);
        final metrics = painter.computeLineMetrics();
        if (metrics.any((line) => line.width > columnWidth + .1)) {
          painter.dispose();
          return null;
        }
        var lineTop = 0.0;
        for (final line in metrics) {
          final position = painter.getPositionForOffset(
            Offset(line.left, lineTop + line.height / 2),
          );
          final lineRange = painter.getLineBoundary(position);
          if (lineRange.start < lineRange.end) {
            segments.add(
              MeasuredSegment(
                start: start + lineRange.start,
                end: start + lineRange.end,
                left: x + line.left,
                width: line.width,
                top: y + lineTop,
                baseline: line.baseline - lineTop,
              ),
            );
          }
          lineTop += line.height;
        }
        y += painter.height;
        painter.dispose();
      }
      if (segments.isEmpty) return null;
      final valign = style.text.verticalAlign;
      final usedHeight =
          column.margin.vertical +
          column.size.height.use(y - column.margin.top);
      columns.add((
        segments: segments,
        height: usedHeight,
        valign: valign is VerticalAlignKeyword ? valign.keyword : null,
      ));
      rowHeight = math.max(rowHeight, usedHeight);
      x += columnWidth + column.margin.right;
      previousEnd = range.end;
    }
    if (text.substring(previousEnd).trim().isNotEmpty) return null;
    return MeasuredLine(
      start: 0,
      end: text.length,
      width: x,
      height: rowHeight,
      stacked: true,
      segments: [
        for (final column in columns)
          for (final segment in column.segments)
            _moveSegment(segment, switch (column.valign) {
              'middle' => (rowHeight - column.height) / 2,
              'bottom' => rowHeight - column.height,
              _ => 0.0,
            }),
      ],
    );
  }
}

MeasuredSegment _moveSegment(MeasuredSegment segment, double down) =>
    MeasuredSegment(
      start: segment.start,
      end: segment.end,
      left: segment.left,
      width: segment.width,
      top: segment.top + down,
      baseline: segment.baseline,
      letterSpacing: segment.letterSpacing,
      ruby: segment.ruby,
    );

double _stackFloatLines(
  List<MeasuredLine> lines,
  ({int end, MeasuredSegment glyph, double width, double height}) leadingFloat,
) {
  final segments = [leadingFloat.glyph];
  var height = 0.0, lineWidth = 0.0, count = 0;
  // 字形压住的几行作为一个分页行带，页尾不能剪掉大字的下半截。
  do {
    final line = lines[count++];
    segments.addAll(
      line.segments.map(
        (segment) => _moveSegment(segment, height + line.textTop),
      ),
    );
    height += line.height;
    lineWidth = math.max(lineWidth, line.width);
  } while (count < lines.length && height < leadingFloat.height - .1);
  final combinedHeight = math.max(height, leadingFloat.height);
  final end = lines[count - 1].end;
  lines.replaceRange(0, count, [
    MeasuredLine(
      start: 0,
      end: end,
      height: combinedHeight,
      width: lineWidth,
      segments: segments,
      stacked: true,
    ),
  ]);
  return combinedHeight - height;
}
