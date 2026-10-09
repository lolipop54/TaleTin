import '../models/book_document.dart';

/// 阅读和听书共用章节权重；章内图片/分隔符沿用正文的一个位置单位。
double bookProgressAt(
  List<Chapter> chapters,
  int total,
  int index,
  double fraction,
) {
  if (chapters.isEmpty || total <= 0) return 0;
  final safe = index.clamp(0, chapters.length - 1);
  var read = 0.0;
  for (var i = 0; i < safe; i++) {
    read += chapters[i].textLength;
  }
  read += chapters[safe].textLength * fraction.clamp(0.0, 1.0);
  return (read / total).clamp(0.0, 1.0);
}
