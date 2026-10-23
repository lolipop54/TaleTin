import 'dart:convert';

import 'package:drift/drift.dart';

import '../../domain/models/book_document.dart';
import '../../domain/models/locator.dart';
import '../../engine/normalization/locator_mapper.dart';
import '../database/app_database.dart';
import '../mappers/book_mapper.dart';

/// 旧记录没有摘录或图片路径时，只从改动前已保存的正文/缓存补充证据。
/// 找不到旧缓存就保留原记录；绝不从已经改变的原文件生成“旧原文”。
Future<void> backfillSourceLocations(
  AppDatabase db,
  String bookId,
  Future<ChapterContent?> Function(Chapter) cachedChapter,
) async {
  final rows = await (db.select(
    db.chapters,
  )..where((t) => t.bookId.equals(bookId))).get();
  final chapters = {for (final row in rows) row.id: chapterFromRow(row)};
  final cache = <String, Future<ChapterContent?>>{};
  Future<String> enrich(String raw) async {
    final value = jsonDecode(raw) as Map<String, dynamic>;
    final old = Locator.fromJson(value);
    if (old.needsRelocation ||
        old.imageResource != null ||
        (old.exact.isNotEmpty &&
            old.prefix.isNotEmpty &&
            old.suffix.isNotEmpty)) {
      return raw;
    }
    final chapter = chapters[old.chapterId];
    if (chapter == null) return raw;
    final content = await cache.putIfAbsent(
      chapter.id,
      () => cachedChapter(chapter),
    );
    if (content == null) return raw;
    final block = content.blocks.where((b) => b.id == old.blockId).firstOrNull;
    if (block == null) return raw;
    final text = blockTextOf(block);
    if (old.utf16Offset < 0 || old.utf16Offset > text.length) return raw;
    final at = old.utf16Offset;
    if ((old.exact.isNotEmpty && !text.substring(at).startsWith(old.exact)) ||
        (old.prefix.isNotEmpty &&
            !text.substring(0, at).endsWith(old.prefix)) ||
        (old.suffix.isNotEmpty && !text.substring(at).startsWith(old.suffix))) {
      return raw;
    }
    final found = LocatorMapper(
      bookId: bookId,
      contentVersion: old.contentVersion,
      chapterId: old.chapterId,
    ).at(block, at, affinity: old.affinity);
    return jsonEncode({
      // 位置 JSON 还携带视觉/听书来源及进度口径。这里只补坐标证据，
      // 不能通过 Locator.toJson 把这些扩展字段一并丢掉。
      ...value,
      ...old
          .copyWith(
            exact: found.exact,
            prefix: found.prefix,
            suffix: found.suffix,
            imageResource: found.imageResource,
          )
          .toJson(),
    });
  }

  // 逐项比较当前值，编辑器恰好写入新选区时不覆盖它；正文和编辑时间不动。
  final positions = await (db.select(
    db.readingPositions,
  )..where((t) => t.bookId.equals(bookId))).get();
  for (final row in positions) {
    final value = await enrich(row.locatorJson);
    if (value != row.locatorJson) {
      await (db.update(db.readingPositions)..where(
            (t) =>
                t.bookId.equals(bookId) & t.locatorJson.equals(row.locatorJson),
          ))
          .write(ReadingPositionsCompanion(locatorJson: Value(value)));
    }
  }
  final notes = await (db.select(
    db.annotations,
  )..where((t) => t.bookId.equals(bookId))).get();
  for (final row in notes) {
    final start = await enrich(row.startLocatorJson);
    final end = row.endLocatorJson == null
        ? null
        : await enrich(row.endLocatorJson!);
    if (start == row.startLocatorJson && end == row.endLocatorJson) continue;
    await (db.update(db.annotations)..where(
          (t) =>
              t.id.equals(row.id) &
              t.startLocatorJson.equals(row.startLocatorJson) &
              (row.endLocatorJson == null
                  ? t.endLocatorJson.isNull()
                  : t.endLocatorJson.equals(row.endLocatorJson!)),
        ))
        .write(
          AnnotationsCompanion(
            startLocatorJson: Value(start),
            endLocatorJson: Value(end),
          ),
        );
  }
  final drafts =
      await (db.select(db.preferences)..where(
            (t) =>
                t.scope.equals('book') &
                t.scopeId.equals(bookId) &
                t.key.equals('noteDraft'),
          ))
          .get();
  for (final row in drafts) {
    final value = jsonDecode(row.valueJson) as Map<String, dynamic>;
    for (final key in ['start', 'end']) {
      value[key] = jsonDecode(await enrich(jsonEncode(value[key])));
    }
    final updated = jsonEncode(value);
    if (updated != row.valueJson) {
      await (db.update(db.preferences)..where(
            (t) =>
                t.scope.equals('book') &
                t.scopeId.equals(bookId) &
                t.key.equals('noteDraft') &
                t.valueJson.equals(row.valueJson),
          ))
          .write(PreferencesCompanion(valueJson: Value(updated)));
    }
  }
}
