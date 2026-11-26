import '../models/book_document.dart';

/// 稳定正文坐标上的分段索引。不同格式可从字节范围或已转换的小文件读段。
abstract interface class ChapterSections {
  Object get identity;
  int get count;
  String get firstBlockId;
  int offsetOf(int section);
  int forOffset(int offset);
  int forBlock(String blockId);
  int? orderOf(String blockId);
  String? chapterStartFor(String blockId);
  String? get lastChapterStart;
  Future<ChapterContent> readSection(int section);
  Future<ChapterContent> readSectionForCount(int section);
}

int sectionBlockNumber(String id) =>
    id.startsWith('b') ? int.tryParse(id.substring(1)) ?? -1 : -1;

int sectionIndexAt(int count, int value, int Function(int) start) {
  var first = 0, last = count - 1;
  while (first < last) {
    final middle = (first + last + 1) ~/ 2;
    if (start(middle) <= value) {
      first = middle;
    } else {
      last = middle - 1;
    }
  }
  return first;
}
