import '../../domain/models/book_document.dart';

// ReaderMath 已包含这些有文字/emoji 两种显示形式的箭头和几何符号。
// 裸符号以及明确指定文字形态的符号使用单色字体；保留作者写的 FE0F。
final _textSymbols = RegExp(
  r'[\u2194-\u2199\u25aa\u25ab\u25b6\u25c0](?!\ufe0f)',
);

Set<int> bookTextSymbolOffsets(String text, int from) => {
  for (final match in _textSymbols.allMatches(text)) from + match.start,
};

/// 长留白和单色符号各取自己的显示样式，原文及 UTF-16 位置保持不变。
List<TextRun> splitDisplayRuns(
  List<TextRun> runs,
  Iterable<int> isolatedOffsets,
  int from,
) {
  if (isolatedOffsets.isEmpty) return runs;
  final result = <TextRun>[];
  var cursor = from;
  for (final run in runs) {
    final end = cursor + run.text.length;
    final cuts = <int>{
      cursor,
      end,
      for (final at in isolatedOffsets)
        if (at >= cursor && at < end) ...[at, at + 1],
    }.toList()..sort();
    for (var i = 1; i < cuts.length; i++) {
      result.add(
        TextRun.fromJson({
          ...run.toJson(),
          'text': run.text.substring(cuts[i - 1] - cursor, cuts[i] - cursor),
        }),
      );
    }
    cursor = end;
  }
  return result;
}
