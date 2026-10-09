/// 书签（设计文档 7.1 annotations 表 kind=bookmark）。
///
/// 书签只记一个位置（章节 + 块 + 块内偏移）与一段摘录，不带选区两端，
/// 因此不受排版变化影响：改字号、换主题之后点书签仍然回到同一句话。
library;

import 'locator.dart';

class Bookmark {
  const Bookmark({
    required this.id,
    required this.locator,
    this.quote = '',
    required this.createdAt,
  });

  final String id;

  /// 书签位置
  final Locator locator;

  /// 加书签时页首的摘录（列表里展示）
  final String quote;

  final DateTime createdAt;

  /// 同一个位置只算一个书签（用于「当前位置是否已加书签」）
  bool isAt(Locator other) =>
      locator.chapterId == other.chapterId &&
      locator.blockId == other.blockId &&
      locator.utf16Offset == other.utf16Offset;
}
