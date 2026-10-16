import 'dart:convert';

import 'package:drift/drift.dart';

import '../../domain/models/locator.dart';
import '../../domain/models/annotation.dart';
import '../../domain/models/note_draft.dart';
import '../../domain/models/book_document.dart';
import '../../domain/repositories/book_repository.dart';
import '../../domain/repositories/chapter_content_repository.dart';
import '../database/app_database.dart';
import '../repositories/drift_annotation_repository.dart';
import 'annotation_locator_service.dart';
import 'source_position_resolver.dart';

/// 自动更新不修改笔记正文、创建时间或最后编辑时间；找不到的仍保留原定位证据。
Future<void> refreshSavedAnnotations(
  AppDatabase db,
  BookRepository books,
  ChapterContentRepository contents,
  String bookId, {
  SourcePositionResolver? resolver,
}) async {
  final repository = DriftAnnotationRepository(db);
  final notes = (await repository.loadForRelocation(bookId))
      .where(
        (note) =>
            note.start.needsRelocation || note.end?.needsRelocation == true,
      )
      .toList();
  final chapters = await books.chaptersOf(bookId);
  final positions = await (db.select(
    db.readingPositions,
  )..where((t) => t.bookId.equals(bookId))).get();
  final draftRow =
      await (db.select(db.preferences)..where(
            (t) =>
                t.scope.equals('book') &
                t.scopeId.equals(bookId) &
                t.key.equals('noteDraft'),
          ))
          .getSingleOrNull();
  final draft = draftRow == null
      ? null
      : NoteDraft.fromJson(
          (jsonDecode(draftRow.valueJson) as Map).cast<String, Object?>(),
        );
  final anchors = [
    for (final note in notes) ...[note.start, if (note.end != null) note.end!],
    for (final row in positions)
      if (Locator.fromJson(jsonDecode(row.locatorJson)).needsRelocation)
        Locator.fromJson(jsonDecode(row.locatorJson)),
    if (draft != null &&
        (draft.range.start.needsRelocation ||
            draft.range.end.needsRelocation)) ...[
      draft.range.start,
      draft.range.end,
    ],
  ];
  final points = resolver ?? SourcePositionResolver(contents);
  final found = await points.resolveMany(anchors, chapters);
  final matches = {
    for (var i = 0; i < anchors.length; i++)
      jsonEncode(anchors[i].toJson()): found[i],
  };
  final decoded = <String, ChapterContent>{};
  Future<ChapterContent> read(String id, Chapter chapter) async {
    final cached = decoded[chapter.id];
    if (cached != null) return cached;
    final result = await contents.chapter(id, chapter, textOnly: true);
    if (result.textLength <= 500000) {
      decoded[chapter.id] = result;
      while (decoded.length > 4 ||
          decoded.values.fold<int>(0, (n, c) => n + c.textLength) > 500000) {
        decoded.remove(decoded.keys.first);
      }
    }
    return result;
  }

  final locator = AnnotationLocatorService(books, contents, readChapter: read);
  await _refreshDraft(db, bookId, draft, draftRow?.valueJson, matches, locator);
  if (notes.isEmpty) return;
  final updates = <String, (Locator, Locator?)>{};
  for (final note in notes) {
    if (note.isBookmark) {
      final resolved = matches[jsonEncode(note.start.toJson())];
      if (resolved != null) updates[note.id] = (resolved, null);
      continue;
    }
    try {
      final start = matches[jsonEncode(note.start.toJson())];
      final end = matches[jsonEncode(note.end!.toJson())];
      if (start == null || end == null) continue;
      final resolved = await locator.resolve(
        note.copyWith(start: start, end: end),
      );
      updates[note.id] = (resolved.start, resolved.end);
    } on AnnotationLocationFailure {
      // 摘录删掉或重复时保留笔记，界面不会绘制未经核对的旧高亮。
    }
  }
  if (updates.isEmpty) return;
  await db.transaction(() async {
    for (final entry in updates.entries) {
      final original = notes.firstWhere((note) => note.id == entry.key);
      await _saveLocations(db, original, entry.value.$1, entry.value.$2);
    }
  });
}

Future<void> _refreshDraft(
  AppDatabase db,
  String bookId,
  NoteDraft? draft,
  String? original,
  Map<String, Locator?> matches,
  AnnotationLocatorService locator,
) async {
  if (draft == null ||
      (!draft.range.start.needsRelocation &&
          !draft.range.end.needsRelocation)) {
    return;
  }
  try {
    final start = matches[jsonEncode(draft.range.start.toJson())];
    final end = matches[jsonEncode(draft.range.end.toJson())];
    if (start == null || end == null) return;
    final resolved = await locator.resolve(
      Annotation(
        id: 'draft',
        bookId: bookId,
        kind: AnnotationKind.note,
        start: start,
        end: end,
        quote: draft.quote,
        createdAt: draft.savedAt,
      ),
    );
    final updated = NoteDraft(
      range: resolved.range,
      quote: draft.quote,
      body: draft.body,
      chapterTitle: draft.chapterTitle,
      savedAt: draft.savedAt,
    );
    await (db.update(db.preferences)..where(
          (t) =>
              t.scope.equals('book') &
              t.scopeId.equals(bookId) &
              t.key.equals('noteDraft') &
              t.valueJson.equals(original!),
        ))
        .write(
          PreferencesCompanion(valueJson: Value(jsonEncode(updated.toJson()))),
        );
  } on AnnotationLocationFailure {
    // 摘录已删除/重复的草稿保留，不能套用旧选区。
  }
}

/// 跨书笔记打开时重新读数据库里的坐标，不能使用更新前列表持有的旧对象。
Future<Annotation> refreshSavedAnnotation(
  AppDatabase db,
  BookRepository books,
  ChapterContentRepository contents,
  Annotation old, {
  SourcePositionResolver? resolver,
}) async {
  final notes = await DriftAnnotationRepository(db)
      .loadForRelocation(old.bookId);
  final current = notes.where((note) => note.id == old.id).firstOrNull;
  if (current == null) throw const AnnotationLocationFailure('这条笔记已删除');
  var prepared = current;
  if (resolver != null &&
      (current.start.needsRelocation || current.end?.needsRelocation == true)) {
    final chapters = await books.chaptersOf(current.bookId);
    final found = await resolver.resolveMany([
      current.start,
      current.end!,
    ], chapters);
    if (found.any((p) => p == null)) {
      throw const AnnotationLocationFailure('正文已变化，无法准确定位，笔记已保留');
    }
    prepared = current.copyWith(start: found[0], end: found[1]);
  }
  final resolved = await AnnotationLocatorService(
    books,
    contents,
  ).resolve(prepared);
  await db.transaction(
    () => _saveLocations(db, current, resolved.start, resolved.end),
  );
  return resolved;
}

Future<void> _saveLocations(
  AppDatabase db,
  Annotation original,
  Locator start,
  Locator? end,
) async {
  final row = await (db.select(
    db.annotations,
  )..where((t) => t.id.equals(original.id))).getSingleOrNull();
  if (row == null ||
      Locator.fromJson(jsonDecode(row.startLocatorJson)) != original.start ||
      (row.endLocatorJson == null
              ? null
              : Locator.fromJson(jsonDecode(row.endLocatorJson!))) !=
          original.end) {
    return;
  }
  await (db.update(
    db.annotations,
  )..where((t) => t.id.equals(original.id))).write(
    AnnotationsCompanion(
      startLocatorJson: Value(jsonEncode(start.toJson())),
      endLocatorJson: end == null
          ? const Value.absent()
          : Value(jsonEncode(end.toJson())),
    ),
  );
}
