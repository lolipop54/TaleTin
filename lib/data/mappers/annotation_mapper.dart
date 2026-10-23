import 'dart:convert';

import '../../domain/models/annotation.dart';
import '../../domain/models/bookmark.dart';
import '../../domain/models/locator.dart';
import '../database/app_database.dart';

Bookmark bookmarkFromRow(AnnotationRow row) => Bookmark(
  id: row.id,
  locator: decodeAnnotationLocator(row.startLocatorJson),
  quote: row.quote,
  createdAt: row.createdAt,
);

/// 数据库行 → 领域模型。位置 JSON 坏掉时给空位置：列表里仍看得到摘录，
/// 点它不会有反应，不会因为一条坏数据让整个笔记页打不开。
Annotation annotationFromRow(AnnotationRow row) => Annotation(
  id: row.id,
  bookId: row.bookId,
  kind: AnnotationKind.fromCode(row.kind),
  start: decodeAnnotationLocator(row.startLocatorJson),
  end: row.endLocatorJson == null
      ? null
      : decodeAnnotationLocator(row.endLocatorJson!),
  quote: row.quote,
  body: row.body,
  color: AnnotationColor.fromCode(row.colorToken),
  chapterTitle: row.chapterTitle,
  createdAt: row.createdAt,
  // v3 老行没有修改时间，按创建时间算（模型自己兜底）
  updatedAt: row.updatedAt,
);

/// 位置 JSON 坏掉时给一个空位置：列表里仍能看到书签，点它不会有反应
Locator decodeAnnotationLocator(String json) {
  try {
    final decoded = jsonDecode(json);
    if (decoded is Map<String, Object?>) return Locator.fromJson(decoded);
  } on FormatException {
    // 落到下面的兜底
  }
  return const Locator(
    bookId: '',
    contentVersion: 1,
    chapterId: '',
    blockId: '',
    utf16Offset: 0,
  );
}
