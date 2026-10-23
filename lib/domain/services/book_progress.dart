import '../models/book_document.dart';

// 章节清单是不可原地修改的会话快照；换书/更新正文使用新清单，旧缓存随其回收。
final _prefixes = Expando<List<double>>('chapter-prefixes');

List<double> chapterTextPrefixes(List<Chapter> chapters) =>
    _prefixes[chapters] ??= _buildPrefixes(chapters);

List<double> _buildPrefixes(List<Chapter> chapters) {
  final result = <double>[0];
  for (final chapter in chapters) {
    result.add(result.last + chapter.textLength);
  }
  return result;
}

/// 阅读和听书共用章节权重；章内图片/分隔符沿用正文的一个位置单位。
double bookProgressAt(
  List<Chapter> chapters,
  int total,
  int index,
  double fraction,
) {
  if (chapters.isEmpty || total <= 0) return 0;
  final safe = index.clamp(0, chapters.length - 1);
  var read = chapterTextPrefixes(chapters)[safe];
  read += chapters[safe].textLength * fraction.clamp(0.0, 1.0);
  return (read / total).clamp(0.0, 1.0);
}
