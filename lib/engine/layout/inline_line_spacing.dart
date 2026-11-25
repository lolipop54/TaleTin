part of 'block_measure.dart';

/// 字体基线和整行高度取整后可能相差不足一个逻辑像素。角标的边线
/// 延到行框边缘；文字基线和作者有意留出的行距都保留。
Rect _inlineBorderRect(
  Rect rect,
  double height, {
  required bool atTop,
  required bool atBottom,
}) {
  if (!atTop && !atBottom) return rect;
  final top = atTop && rect.top > 0 && rect.top < 1 ? 0.0 : rect.top;
  final gap = height - rect.bottom;
  final bottom = atBottom && gap > 0 && gap < 1 ? height : rect.bottom;
  return top == rect.top && bottom == rect.bottom
      ? rect
      : Rect.fromLTRB(rect.left, top, rect.right, bottom);
}

extension _ExplicitBlankLines on BlockMeasurer {
  /// 只给当前片段实际拥有的换行留白。嵌套行内盒的空行由盒子自己测量。
  Map<int, List<double>> _blankLineHeights(
    ContentBlock block,
    int? index,
    int sourceOffset,
    int prefixLength,
    bool Function(int) owns,
  ) {
    final byOffset = displayTree?.blankLines[index];
    if (byOffset == null) return const {};
    final heights = <int, double>{};
    final result = <int, List<double>>{};
    final end = sourceOffset + block.runLength;
    for (final entry in byOffset.entries) {
      if (entry.key < sourceOffset ||
          entry.key > end ||
          (entry.key == end && end != displayTree!.textLengths[index])) {
        continue;
      }
      for (final br in entry.value) {
        if (!owns(br.id)) continue;
        final styleId = br.styleId ?? 0;
        final height = heights.putIfAbsent(styleId, () {
          final font = _sourceFont(block, styleTable![styleId]);
          return font.height != null &&
                  font.fontSize != null &&
                  font.height! > 0
              ? options.textScaler.scale(font.fontSize!) * font.height!
              : _lineStrut(font).height;
        });
        (result[entry.key - sourceOffset + prefixLength] ??= []).add(height);
      }
    }
    return result;
  }
}

/// 按各片段实际可拉伸的宽度分配同一行的剩余空间，同步移动图片及注音。
(List<MeasuredSegment>, List<_InlineSpec>, double) _justifyInlineLine(
  List<MeasuredSegment> segments,
  List<_InlineSpec> pending,
  List<TextRun> runs,
  List<TextStyle> styles,
  int prefixLength,
  double remaining,
  TextScaler scaler,
) {
  final gains = <double>[];
  for (final segment in segments) {
    double widthAt(double spacing) {
      final painter = EdgeAlignedTextPainter(
        text: TextSpan(
          children: BlockMeasurer._slice(
            runs,
            styles,
            segment.start,
            segment.end,
            fixedPrefixLength: prefixLength,
            letterSpacing: spacing,
          ),
        ),
        textScaler: scaler,
        spacing: spacing,
        fixedPrefixLength: (prefixLength - segment.start).clamp(
          0,
          segment.end - segment.start,
        ),
      )..layout();
      final result = painter.width;
      painter.dispose();
      return result;
    }

    gains.add(segment.ruby == null ? math.max(0, widthAt(1) - widthAt(0)) : 0);
  }
  // 缩进独立成段时，其后也不能再补一份两端对齐字距。
  final gaps = [
    for (var i = 0; i < segments.length; i++)
      i + 1 < segments.length && segments[i].end > prefixLength ? 1.0 : 0.0,
  ];
  final gain =
      gains.fold<double>(0, (n, v) => n + v) +
      gaps.fold<double>(0, (n, v) => n + v);
  final spacing = gain > 0 ? math.max(0.0, remaining) / gain : 0.0;
  pending = [
    for (final image in pending)
      image.at(
        image.left +
            [
              for (var i = 0; i < segments.length; i++)
                if (segments[i].end <= image.offset)
                  (gains[i] + gaps[i]) * spacing,
            ].fold(0.0, (a, b) => a + b),
      ),
  ];
  var shift = 0.0;
  segments = [
    for (var i = 0; i < segments.length; i++)
      (() {
        final old = segments[i];
        final next = MeasuredSegment(
          start: old.start,
          end: old.end,
          left: old.left + shift,
          width: old.width + gains[i] * spacing,
          letterSpacing: old.ruby == null ? spacing : 0,
          baseline: old.baseline,
          top: old.top,
          ruby: old.ruby,
        );
        shift += (gains[i] + gaps[i]) * spacing;
        return next;
      })(),
  ];
  return (segments, pending, shift);
}
