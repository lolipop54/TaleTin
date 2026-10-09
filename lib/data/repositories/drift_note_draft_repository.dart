/// [NoteDraftRepository] 的 drift 实现（设计文档 7.1 preferences 表）。
///
/// 草稿按书一行：`scope = book`、`scopeId = bookId`、`key = noteDraft`。
/// 复用偏好表是为了跟其它本地状态一样走同一套事务与迁移，
/// 但草稿不是偏好：清缓存、恢复默认都不会碰它。
library;

import 'dart:convert';

import 'package:drift/drift.dart';

import '../../domain/models/note_draft.dart';
import '../../domain/repositories/note_draft_repository.dart';
import '../database/app_database.dart';

class DriftNoteDraftRepository implements NoteDraftRepository {
  DriftNoteDraftRepository(this._db);

  final AppDatabase _db;

  /// 草稿在偏好表里的键（一本书一行）
  static const String draftKey = 'noteDraft';

  static const String _bookScope = 'book';

  @override
  Future<NoteDraft?> load(String bookId) async {
    final row = await (_db.select(_db.preferences)
          ..where((t) =>
              t.scope.equals(_bookScope) &
              t.scopeId.equals(bookId) &
              t.key.equals(draftKey)))
        .getSingleOrNull();
    if (row == null) return null;
    try {
      final decoded = jsonDecode(row.valueJson);
      if (decoded is! Map<String, Object?>) return null;
      return NoteDraft.fromJson(decoded);
    } on FormatException {
      // 草稿坏了就当没有：不能因为一份坏草稿让阅读页打不开
      return null;
    }
  }

  @override
  Future<void> save(String bookId, NoteDraft draft) async {
    await _db.into(_db.preferences).insertOnConflictUpdate(
          PreferencesCompanion.insert(
            scope: _bookScope,
            scopeId: bookId,
            key: draftKey,
            valueJson: jsonEncode(draft.toJson()),
            updatedAt: DateTime.now().toUtc(),
          ),
        );
  }

  @override
  Future<void> clear(String bookId) async {
    await (_db.delete(_db.preferences)
          ..where((t) =>
              t.scope.equals(_bookScope) &
              t.scopeId.equals(bookId) &
              t.key.equals(draftKey)))
        .go();
  }
}
