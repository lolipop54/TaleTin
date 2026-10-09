/// [ReadingPositionRepository] 的 drift 实现（设计文档 7.1）。
///
/// 位置按 JSON 存整行覆盖；解码失败（旧格式或坏数据）当作没读过，
/// 让上层回到「从第一段正文开始」，而不是卡在错误上。
library;

import 'dart:convert';

import 'package:drift/drift.dart';

import '../../domain/models/locator.dart';
import '../../domain/repositories/reading_position_repository.dart';
import '../database/app_database.dart';

class DriftReadingPositionRepository implements ReadingPositionRepository {
  DriftReadingPositionRepository(this._db);

  final AppDatabase _db;

  @override
  Future<ReadingPosition?> load(String bookId) async {
    final row = await (_db.select(
      _db.readingPositions,
    )..where((t) => t.bookId.equals(bookId))).getSingleOrNull();
    if (row == null) return null;
    final Object? decoded;
    try {
      decoded = jsonDecode(row.locatorJson);
    } on FormatException {
      return null;
    }
    if (decoded is! Map<String, Object?>) return null;
    final locator = Locator.fromJson(decoded);
    // 章节与块都空的记录没有恢复价值
    if (locator.chapterId.isEmpty || locator.blockId.isEmpty) return null;
    return ReadingPosition(
      locator: locator,
      source: decoded['source'] == 'listening'
          ? ReadingPositionSource.listening
          : ReadingPositionSource.visual,
      // v2 写下的行没有进度，按 0 处理（书架会退回按章边界估算）
      progress: (row.progress ?? 0).clamp(0.0, 1.0),
    );
  }

  @override
  Future<void> save(ReadingPosition position) async {
    await _db
        .into(_db.readingPositions)
        .insertOnConflictUpdate(
          ReadingPositionsCompanion.insert(
            bookId: position.locator.bookId,
            locatorJson: jsonEncode({
              ...position.locator.toJson(),
              'source': position.source.name,
            }),
            progress: Value(position.progress.clamp(0.0, 1.0)),
            updatedAt: DateTime.now().toUtc(),
          ),
        );
  }
}
