part of 'block_measure.dart';

// 只在可独立换行的位置截取预览。双向控制、组合文字等需要完整上下文时，
// 仍从真实行首量到事件末尾。区间中的软连字符和字符偏移交给原有显示映射。
final _inlineContextualText = RegExp(
  r'[^ -~\u00a0-\u024f\u2000-\u200b\u2010-\u2027\u2030-\u205e\u3000-\u303f\u4e00-\u9fff\uff01-\uff60]',
);

int _inlineWindowEnd(String text, int target, int to) {
  for (var end = target; end < to; end++) {
    final before = text.codeUnitAt(end - 1), after = text.codeUnitAt(end);
    if (before == 32 && after != 32 ||
        before >= 0x4e00 &&
            before <= 0x9fff &&
            after >= 0x4e00 &&
            after <= 0x9fff) {
      return end;
    }
  }
  return to;
}

extension _InlineWrapping on BlockMeasurer {
  ({TextPainter painter, List<LineMetrics> metrics, HyphenatedText display})
  _shapeInlineWindow({
    required String text,
    required List<TextRun> runs,
    required List<TextStyle> styles,
    required int from,
    required int to,
    required int prefixLength,
    required bool bounded,
    required int initialLength,
    required bool rtl,
    required double available,
  }) {
    var length = initialLength;
    while (true) {
      final end = bounded && from + length < to
          ? _inlineWindowEnd(text, from + length, to)
          : to;
      final source = text.substring(from, end);
      final prefixEnd = (prefixLength - from).clamp(0, source.length);
      final displaySource =
          FixedIndent.display(source.substring(0, prefixEnd)) +
          source.substring(prefixEnd);
      final display = authorTableCell
          ? ProseLineBreaks.tableText(displaySource)
          : ProseLineBreaks.display(displaySource, hyphenate: false);
      var displayCursor = 0;
      final displaySpans = BlockMeasurer._slice(
        runs,
        styles,
        from,
        end,
        fixedPrefixLength: prefixLength,
      ).cast<TextSpan>();
      final fitsInsertedHyphens = display.insertions.any(
        (i) => display.text.codeUnitAt(i) == 0xad,
      );
      final painter = TextPainter(
        text: TextSpan(
          children: [
            for (final span in displaySpans)
              TextSpan(
                text: display.text.substring(
                  display.displayOffset(displayCursor),
                  display.displayOffset(displayCursor += span.text!.length),
                ),
                style: span.style,
              ),
          ],
        ),
        textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
        textScaler: options.textScaler,
        // 双向文本保留整个剩余段落供引擎决定方向，只取定位首行所需的两行。
        // 如果需要校验显示层新增的断字符宽度，仍检查完整的排版结果。
        maxLines: fitsInsertedHyphens ? null : (bounded ? 3 : 2),
      )..layout(maxWidth: available);
      if (fitsInsertedHyphens) {
        _fitHyphenLines(
          painter,
          display,
          [for (final span in displaySpans) TextRun(span.text!)],
          [for (final span in displaySpans) span.style!],
          available,
        );
      }
      final metrics = painter.computeLineMetrics();
      // 截取的最后一行可能因尚未读到的字、标点或空白改变。
      // 保留两行前瞻；宽纸面一段还放得下时扩大窗口再量。
      if (end == to || metrics.length >= 3) {
        return (painter: painter, metrics: metrics, display: display);
      }
      painter.dispose();
      length = (end - from) * 2;
    }
  }
}
