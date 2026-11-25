part of 'block_measure.dart';

/// 行内块自身可以换行；它在父段落里整体占位，子行仍使用原文偏移供选字和定位。
class _InlineTextBox {
  const _InlineTextBox(
    this.end,
    this.baseline,
    this.segments, {
    this.boxes = const [],
    this.images = const [],
  });
  final int end;
  final double baseline;
  final List<MeasuredSegment> segments;
  final List<InlineBoxPlacement> boxes;
  final List<InlineImagePlacement> images;

  Iterable<MeasuredSegment> place(double x, double y) => segments.map(
    (s) => MeasuredSegment(
      start: s.start,
      end: s.end,
      left: x + s.left,
      top: y + s.top,
      width: s.width,
      baseline: s.baseline,
      letterSpacing: s.letterSpacing,
      ruby: s.ruby,
    ),
  );
}

extension _InlineTextBoxMeasurement on BlockMeasurer {
  bool _insideInline(int id, int parent) {
    final source = displayTree?.source;
    for (
      var e = source?.element(id);
      e != null;
      e = e.parent == null ? null : source?.element(e.parent!)
    ) {
      if (e.id == parent) return true;
    }
    return false;
  }

  List<_InlineSpec> _inlineTextBoxes(
    ContentBlock block,
    List<TextRun> runs,
    List<TextStyle> styles,
    String text,
    double width,
    double? parentHeight,
    int index,
    int shift,
    List<(int, int)> hidden,
    List<RubyRange> ruby,
    List<_InlineSpec> formulas,
    Set<int> boundaries,
    int prefixLength,
    int? inside,
  ) {
    final result = <_InlineSpec>[];
    for (final node in _inlineCandidates(block)) {
      final id = node.element.id;
      if (node.display != DisplaySpec.inlineBlock ||
          (inside != null && (id == inside || !_insideInline(id, inside)))) {
        continue;
      }
      final range = _textRange(node, index);
      if (range == null) continue;
      final start = range.start + shift, end = range.end + shift;
      if (start < 0 ||
          end > text.length ||
          result.any((a) => a.textBox!.end > start) ||
          hidden.any((r) => r.$1 < end && r.$2 > start) ||
          formulas.any((f) => f.offset < end && f.formula!.end > start) ||
          ruby.any((r) => r.start < range.end && r.baseEnd > range.start) ||
          end <= start) {
        continue;
      }
      final style = styleTable![node.element.styleId ?? 0];
      final context = _lengthContext(style, width);
      final box = resolveBlockBox(style.box, context);
      final m = style.block.margin?.resolve(context);
      final margin = EdgeInsets.fromLTRB(
        m?.left ?? 0,
        m?.top ?? 0,
        m?.right ?? 0,
        m?.bottom ?? 0,
      );
      final sizes = BoxSizeResolver(
        context,
        style.size,
        box,
        parentHeight: parentHeight,
      );
      final left = margin.left + (box?.insetLeft ?? 0),
          top = margin.top + (box?.insetTop ?? 0);
      final horizontal = left + margin.right + (box?.insetRight ?? 0);
      final vertical = top + margin.bottom + (box?.insetBottom ?? 0);
      final painter = TextPainter(
        text: TextSpan(
          children: BlockMeasurer._slice(runs, styles, start, end),
        ),
        textAlign: switch (style.block.textAlign) {
          TextAlignSpec.center => TextAlign.center,
          TextAlignSpec.right => TextAlign.right,
          _ => TextAlign.left,
        },
        textDirection: TextDirection.ltr,
        textScaler: options.textScaler,
      )..layout();
      final contentWidth = sizes.width.use(
        math.min(
          painter.maxIntrinsicWidth,
          math.max(painter.minIntrinsicWidth, width - horizontal),
        ),
      );
      final segments = <MeasuredSegment>[],
          childBoxes = <InlineBoxPlacement>[],
          childImages = <InlineImagePlacement>[];
      double baseline, contentHeight;
      final nested =
          block.inlineBoxes.any((b) => b.id != id && _insideInline(b.id, id)) ||
          _inlineCandidates(
            block,
          ).any((n) => n.element.id != id && _insideInline(n.element.id, id)) ||
          block.inlineImages.any(
            (i) =>
                i.offset >= start - prefixLength &&
                i.offset <= end - prefixLength,
          ) ||
          boundaries.any((i) => i > start && i < end);
      if (nested && contentWidth > 0) {
        final sliced = _sliceDisplayBlock(
          block,
          start - prefixLength,
          end - prefixLength,
        );
        var cursor = 0;
        final innerStyles = <TextStyle>[];
        for (final (i, run) in runs.indexed) {
          if (cursor + run.text.length > start && cursor < end) {
            innerStyles.add(styles[i]);
          }
          cursor += run.text.length;
        }
        final inner = _measureInlineText(
          block: sliced,
          runs: sliced.runs,
          styles: innerStyles,
          text: text.substring(start, end),
          width: contentWidth,
          contentWidth: contentWidth,
          parentHeight: sizes.height.definite,
          inset: 0,
          markerInset: 0,
          box: null,
          textShadow: null,
          prefixLength: 0,
          marker: null,
          align: style.block.textAlign?.name ?? 'left',
          boxIndent: 0,
          marginTop: 0,
          marginBottom: 0,
          sourceOffset: range.start,
          insideInline: id,
          forcedBreaks: {
            for (final point in boundaries)
              if (point > start && point < end) point - start,
          },
        );
        var y = top;
        baseline = top;
        for (final (i, line) in inner.lines.indexed) {
          final x = left + inner.horizontalOffset(i, contentWidth);
          for (final item in line.segments) {
            segments.add(
              MeasuredSegment(
                start: start + item.start,
                end: start + item.end,
                left: x + item.left,
                top: y + line.textTop + item.top,
                width: item.width,
                baseline: item.baseline,
                letterSpacing: item.letterSpacing,
                ruby: item.ruby,
              ),
            );
            baseline = y + line.textTop + item.top + item.baseline;
          }
          for (final b in inner.inlineBoxes.where((b) => b.line == i)) {
            childBoxes.add(_shiftInlineBox(b, Offset(x, y), 0, start));
          }
          for (final im in inner.inlineImages.where((im) => im.line == i)) {
            childImages.add(_shiftInlineImage(im, Offset(x, y), 0, start));
          }
          y += line.height;
        }
        contentHeight = sizes.height.use(inner.height);
      } else {
        painter.layout(minWidth: contentWidth, maxWidth: contentWidth);

        final metrics = painter.computeLineMetrics();
        var y = 0.0;
        for (var i = 0; i < metrics.length; i++) {
          final line = metrics[i];
          final from = i == 0 ? 0 : _lineStartAt(painter, metrics, i, 0);
          final to = i + 1 == metrics.length
              ? end - start
              : _lineStartAt(painter, metrics, i + 1, 0);
          segments.add(
            MeasuredSegment(
              start: start + from,
              end: start + to,
              left: left + line.left,
              top: top + y,
              width: line.width,
              baseline: line.baseline - y,
            ),
          );
          y += line.height;
        }
        contentHeight = sizes.height.use(painter.height);
        baseline = top + (metrics.lastOrNull?.baseline ?? contentHeight);
      }
      final align = style.text.verticalAlign;
      final lift = _inlineBaselineLift(
        style,
        context,
        () => painter.computeLineMetrics().first.height,
      );
      painter.dispose();
      result.add(
        _InlineSpec(
          offset: start,
          elementId: node.element.id,
          resourcePath: '',
          box: box,
          margin: margin,
          verticalAlign: align is VerticalAlignKeyword
              ? align.keyword
              : 'baseline',
          baselineLift: lift,
          textBox: _InlineTextBox(
            end,
            baseline,
            segments,
            boxes: childBoxes,
            images: childImages,
          ),
          size: Size(contentWidth + horizontal, contentHeight + vertical),
        ),
      );
    }
    return result;
  }
}

InlineBoxPlacement _shiftInlineBox(
  InlineBoxPlacement b,
  Offset delta,
  int line,
  int offset,
) => InlineBoxPlacement(
  span: InlineBoxSpan(
    start: b.span.start + offset,
    end: b.span.end + offset,
    id: b.span.id,
    box: b.span.box,
    scale: b.span.scale,
    styleId: b.span.styleId,
    first: b.span.first,
    last: b.span.last,
  ),
  box: b.box,
  line: line,
  rect: b.rect.shift(delta),
  first: b.first,
  last: b.last,
);
InlineImagePlacement _shiftInlineImage(
  InlineImagePlacement im,
  Offset delta,
  int line,
  int offset,
) => InlineImagePlacement(
  offset: im.offset + offset,
  line: line,
  left: im.left + delta.dx,
  top: im.top + delta.dy,
  size: im.size,
  resourcePath: im.resourcePath,
  alt: im.alt,
  imageFit: im.imageFit,
  formula: im.formula,
  noteLink: im.noteLink,
  altIsFootnote: im.altIsFootnote,
);
