/// 数据库行 ↔ 领域实体映射（设计文档第 5 节）。
library;

import 'dart:convert';

import 'package:drift/drift.dart';

import '../../domain/models/book.dart';
import '../../domain/models/book_document.dart';
import '../database/app_database.dart';

Book bookFromRow(BookRow row) => Book(
      id: row.id,
      sourceHash: row.sourceHash,
      title: row.title,
      author: row.author,
      format: BookFormat.fromCode(row.format) ?? BookFormat.txt,
      groupId: row.groupId,
      status: BookStatus.fromCode(row.status),
      contentVersion: row.contentVersion,
      importedAt: row.importedAt,
      deletedAt: row.deletedAt,
      sizeBytes: row.sizeBytes,
      coverPath: row.coverPath,
      coverWidth: row.coverWidth,
      coverHeight: row.coverHeight,
      textLength: row.textLength,
      chapterCount: row.chapterCount,
      warnings: _decodeWarnings(row.warningsJson),
    );

/// 书籍实体 → 数据库行（新增或整行覆盖）。
BooksCompanion bookToCompanion(Book book) => BooksCompanion(
      id: Value(book.id),
      sourceHash: Value(book.sourceHash),
      title: Value(book.title),
      author: Value(book.author),
      format: Value(book.format.code),
      groupId: Value(book.groupId),
      status: Value(book.status.code),
      contentVersion: Value(book.contentVersion),
      importedAt: Value(book.importedAt),
      deletedAt: Value(book.deletedAt),
      sizeBytes: Value(book.sizeBytes),
      coverPath: Value(book.coverPath),
      coverWidth: Value(book.coverWidth),
      coverHeight: Value(book.coverHeight),
      textLength: Value(book.textLength),
      chapterCount: Value(book.chapterCount),
      warningsJson: Value(jsonEncode(book.warnings)),
    );

Chapter chapterFromRow(ChapterRow row) => Chapter(
      id: row.id,
      ordinal: row.ordinal,
      title: row.title,
      contentPath: row.contentPath,
      textLength: row.textLength,
      href: row.href,
    );

ChaptersCompanion chapterToCompanion(String bookId, Chapter chapter) =>
    ChaptersCompanion(
      id: Value(chapter.id),
      bookId: Value(bookId),
      ordinal: Value(chapter.ordinal),
      title: Value(chapter.title),
      contentPath: Value(chapter.contentPath),
      textLength: Value(chapter.textLength),
      href: Value(chapter.href),
    );

/// 提示文案列表解码。内容由本项目写入，损坏时按空列表处理即可。
List<String> _decodeWarnings(String raw) {
  try {
    final decoded = jsonDecode(raw);
    if (decoded is List) {
      return [for (final item in decoded) if (item is String) item];
    }
  } on FormatException {
    // 忽略：按无提示处理
  }
  return const [];
}
