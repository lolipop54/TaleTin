part of 'measured_block.dart';

/// 上下标单独绘制时以小字自身的顶部落笔，而不是普通行的基线。
/// 绘制和点击共用同一套落点，避免把普通行的选区框移高后仍错开小字。
extension ScriptTextGeometry on MeasuredBlock {
  void _visitScripts({
    required int start,
    required int end,
    required TextPainter base,
    required Offset origin,
    required TextScaler scaler,
    Color? color,
    required void Function(TextPainter, Offset, int, int) visit,
  }) {
    var cursor = 0;
    for (var i = 0; i < runs.length; i++) {
      final run = runs[i], runStart = cursor;
      cursor += run.text.length;
      if (!run.isScript) continue;
      final from = math.max(start, runStart), to = math.min(end, cursor);
      if (from >= to) continue;
      final painter = TextPainter(
        text: TextSpan(
          text: run.text.substring(from - runStart, to - runStart),
          style: runStyles[i].copyWith(color: color),
        ),
        textDirection: TextDirection.ltr,
        textScaler: scaler,
      )..layout();
      try {
        final caret = base.getOffsetForCaret(
          TextPosition(offset: from - start),
          Rect.zero,
        );
        final shift =
            (run.superscript ? -kSuperscriptShift : kSubscriptShift) *
            runStyles[i].fontSize!;
        visit(painter, origin + Offset(caret.dx, shift), from, to);
      } finally {
        painter.dispose();
      }
    }
  }

  void paintScripts(
    Canvas canvas, {
    required int lineIndex,
    required TextPainter linePainter,
    required Offset origin,
    required Color color,
    required TextScaler textScaler,
  }) {
    if (!hasScript) return;
    _visitScripts(
      start: lines[lineIndex].start,
      end: lines[lineIndex].end,
      base: linePainter,
      origin: origin,
      scaler: textScaler,
      color: color,
      visit: (p, at, _, _) => p.paint(canvas, at),
    );
  }

  void paintScriptsInSegment(
    Canvas canvas, {
    required int lineIndex,
    required MeasuredSegment segment,
    required TextPainter segmentPainter,
    required Offset origin,
    required Color color,
    required TextScaler textScaler,
  }) {
    if (!hasScript) return;
    _visitScripts(
      start: segment.start,
      end: segment.end,
      base: segmentPainter,
      origin: origin,
      scaler: textScaler,
      color: color,
      visit: (p, at, _, _) => p.paint(canvas, at),
    );
  }

  /// 返回行内实际绘出的小字矩形；坐标相对本行顶部，包含段落横向位置。
  List<Rect> scriptRectsInLine(
    int index,
    int from,
    int to, {
    required TextScaler scaler,
    required double width,
  }) {
    final result = <Rect>[], line = lines[index];
    final left = inset + horizontalOffset(index, width);
    void collect(TextPainter painter, Offset at, int start, int end) {
      final a = math.max(from, start), b = math.min(to, end);
      if (a >= b) return;
      for (final box in painter.getBoxesForSelection(
        TextSelection(baseOffset: a - start, extentOffset: b - start),
      )) {
        result.add(
          Rect.fromLTRB(box.left, box.top, box.right, box.bottom).shift(at),
        );
      }
    }

    if (hasSegmentedText) {
      for (final s in line.segments) {
        final base = createSegmentPainter(
          start: s.start,
          end: s.end,
          letterSpacing: s.letterSpacing,
          textScaler: scaler,
        );
        try {
          _visitScripts(
            start: s.start,
            end: s.end,
            base: base,
            origin: Offset(left + s.left, line.textTop + s.top),
            scaler: scaler,
            visit: collect,
          );
        } finally {
          base.dispose();
        }
      }
    } else {
      final base = createSingleLinePainter(
        lineIndex: index,
        textScaler: scaler,
        letterSpacing: justifySpacingFor(
          index,
          maxWidth: width,
          enabled: justifiesLine(index),
          textScaler: scaler,
        ),
      );
      try {
        _visitScripts(
          start: line.start,
          end: line.end,
          base: base,
          origin: Offset(left, 0),
          scaler: scaler,
          visit: collect,
        );
      } finally {
        base.dispose();
      }
    }
    return result;
  }
}
