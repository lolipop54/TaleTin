part of 'block_measure.dart';

extension _HyphenLineFit on BlockMeasurer {
  /// 部分字体把软连字符量成零宽，实际显示的“-”却有字宽。
  /// 按最终字形复核断行；只有确实溢出时才缩小本轮断行宽度重排。
  void _fitHyphenLines(
    TextPainter painter,
    HyphenatedText display,
    List<TextRun> runs,
    List<TextStyle> styles,
    double width,
  ) {
    // 标点和编号也会插入零宽断点。只有实际插入的软连字符才可能画出字宽。
    if (!display.insertions.any((i) => display.text.codeUnitAt(i) == 0x00ad)) {
      return;
    }
    var available = width;
    while (available > 1) {
      final metrics = painter.computeLineMetrics();
      var excess = 0.0;
      var previous = 0;
      for (var i = 0; i + 1 < metrics.length; i++) {
        final start = previous;
        final end = _lineStartAt(painter, metrics, i + 1, start);
        previous = end;
        if (end == 0 ||
            display.text.codeUnitAt(end - 1) != 0x00ad ||
            !display.insertions.contains(end - 1)) {
          continue;
        }
        final spans = BlockMeasurer._slice(
          runs,
          styles,
          display.sourceOffset(start),
          display.sourceOffset(end),
        );
        final last = spans.lastOrNull as TextSpan?;
        final probe = TextPainter(
          text: TextSpan(
            children: [
              ...spans,
              TextSpan(text: '-', style: last?.style),
            ],
          ),
          textDirection: TextDirection.ltr,
          textScaler: options.textScaler,
        )..layout();
        excess = math.max(excess, probe.width - width);
        probe.dispose();
      }
      if (excess <= .01) return;
      available = math.max(1, available - excess - .05);
      painter.layout(maxWidth: available);
    }
  }
}
