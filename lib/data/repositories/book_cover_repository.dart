import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../../domain/models/book_cover_choice.dart';
import '../../domain/models/book.dart';
import '../../domain/repositories/book_cover_repository.dart';
import '../../domain/services/library_file_gate.dart';
import '../database/app_database.dart';

/// 选择存入既有单书 preferences，原书 cover_path 始终保留。
/// 图片先落盘、再一次提交整批选择；备份和删除复用书库文件交接。
class DriftBookCoverRepository implements BookCoverRepository {
  DriftBookCoverRepository(this.db, this.root, this.gate);
  final AppDatabase db;
  final String root;
  final LibraryFileGate gate;
  static const preferenceKey = 'customCover';

  static Future<Map<BookFormat, BookCoverChoice>> loadDefaults(
    AppDatabase db,
  ) async {
    final rows =
        await (db.select(db.preferences)..where(
              (t) => t.scope.equals('global') & t.key.like('customCover:%'),
            ))
            .get();
    return {
      for (final row in rows)
        ?BookFormat.fromCode(
          row.key.substring('customCover:'.length),
        ): BookCoverChoice.fromJson(
          jsonDecode(row.valueJson) as Map<String, dynamic>,
        ),
    };
  }

  @override
  Future<Map<BookFormat, BookCoverChoice>> loadGlobal() => loadDefaults(db);

  @override
  Future<void> saveGlobal(
    BookFormat format, {
    BookCoverPreset? preset,
    Uint8List? image,
  }) async {
    final release = await gate.enter();
    final unlock = await gate.enterBook('global-cover-${format.code}');
    File? created;
    var committed = false;
    try {
      final old = (await loadGlobal())[format]?.imagePath;
      String? relative;
      if (image != null) {
        relative = 'global-covers/${format.code}/${const Uuid().v4()}.png';
        created = File(p.join(root, relative));
        await created.parent.create(recursive: true);
        await created.writeAsBytes(image, flush: true);
      }
      await db
          .into(db.preferences)
          .insertOnConflictUpdate(
            PreferencesCompanion.insert(
              scope: 'global',
              scopeId: '',
              key: '$preferenceKey:${format.code}',
              valueJson: jsonEncode(
                BookCoverChoice(preset: preset, imagePath: relative).toJson(),
              ),
              updatedAt: DateTime.now().toUtc(),
            ),
          );
      committed = true;
      if (old != null) await _remove(File(p.join(root, old)));
    } finally {
      if (!committed && created != null) await _remove(created);
      unlock();
      release();
    }
  }

  static Future<Map<String, BookCoverChoice>> load(
    AppDatabase db,
    Iterable<String> ids,
  ) async {
    final rows =
        await (db.select(db.preferences)..where(
              (t) =>
                  t.scope.equals('book') &
                  t.scopeId.isIn(ids) &
                  t.key.equals(preferenceKey),
            ))
            .get();
    return {
      for (final row in rows)
        row.scopeId: BookCoverChoice.fromJson(
          jsonDecode(row.valueJson) as Map<String, dynamic>,
        ),
    };
  }

  @override
  Future<void> save(
    Iterable<String> ids, {
    BookCoverPreset? preset,
    Uint8List? image,
  }) async {
    final release = await gate.enter();
    final locks = <void Function()>[];
    final created = <File>[];
    var committed = false;
    try {
      final selected = ids.toSet().toList()..sort();
      for (final id in selected) {
        locks.add(await gate.enterBook(id));
      }
      final existing = await (db.select(
        db.books,
      )..where((t) => t.id.isIn(selected))).get();
      if (existing.length != selected.length) throw StateError('部分书籍已被删除');
      final old = await load(db, selected);
      final choices = <String, BookCoverChoice>{};
      for (final id in selected) {
        String? relative;
        if (image != null) {
          relative = 'covers/${const Uuid().v4()}.png';
          final file = File(p.join(root, id, relative));
          created.add(file);
          await file.parent.create(recursive: true);
          await file.writeAsBytes(image, flush: true);
        }
        // 空选择也保留，明确选择原书封面时不能再被全局设置覆盖。
        choices[id] = BookCoverChoice(preset: preset, imagePath: relative);
      }
      await db.transaction(() async {
        for (final entry in choices.entries) {
          await db
              .into(db.preferences)
              .insertOnConflictUpdate(
                PreferencesCompanion.insert(
                  scope: 'book',
                  scopeId: entry.key,
                  key: preferenceKey,
                  valueJson: jsonEncode(entry.value.toJson()),
                  updatedAt: DateTime.now().toUtc(),
                ),
              );
        }
      });
      committed = true;
      // 提交之后才移除旧导入图，避免失败时损失当前封面。
      for (final entry in old.entries) {
        final path = entry.value.imagePath;
        if (path != null) await _remove(File(p.join(root, entry.key, path)));
      }
    } finally {
      if (!committed) {
        for (final file in created) {
          await _remove(file);
        }
      }
      for (final unlock in locks.reversed) {
        unlock();
      }
      release();
    }
  }

  Future<void> _remove(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      /* 不让旧图清理失败回滚已提交选择；删书时仍会清理。 */
    }
  }
}
