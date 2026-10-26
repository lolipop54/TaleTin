import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../../domain/models/reading_background.dart';
import '../../domain/services/library_file_gate.dart';
import '../database/app_database.dart';

/// 背景共享于所有书籍，文件保存在 library 下，随整库备份且不随删书清除。
class ReadingBackgroundRepository {
  ReadingBackgroundRepository(this.db, this.root, this.gate);
  final AppDatabase db;
  final String root;
  final LibraryFileGate gate;
  static const selectionKey = 'readingBackground';
  static const listKey = 'readingBackgroundImages';
  Future<void> _writing = Future.value();

  Future<T> _enqueue<T>(Future<T> Function() action) {
    final next = _writing.then((_) => action());
    _writing = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  Future<List<ReadingBackground>> customImages() async {
    final row =
        await (db.select(db.preferences)..where(
              (t) =>
                  t.scope.equals('global') &
                  t.scopeId.equals('global') &
                  t.key.equals(listKey),
            ))
            .getSingleOrNull();
    if (row == null) return [];
    final items = (jsonDecode(row.valueJson) as Map)['images'] as List;
    if (items.length > ReadingBackground.limit) {
      throw const FormatException('自定义背景数量超过上限');
    }
    return [
      for (var i = 0; i < items.length; i++)
        ReadingBackground(
          items[i]['id'] as String,
          '自定义${i + 1}',
          path: _safePath(items[i]['path'] as String),
        ),
    ];
  }

  static String _safePath(String path) {
    if (!RegExp(r'^reading-backgrounds/[a-zA-Z0-9-]+\.png$').hasMatch(path)) {
      throw const FormatException('阅读背景图片路径无效');
    }
    return path;
  }

  Future<String?> selection({String? bookId}) async {
    final row =
        await (db.select(db.preferences)..where(
              (t) =>
                  t.scope.equals(bookId == null ? 'global' : 'book') &
                  t.scopeId.equals(bookId ?? 'global') &
                  t.key.equals(selectionKey),
            ))
            .getSingleOrNull();
    return row == null
        ? null
        : (jsonDecode(row.valueJson) as Map)['id'] as String?;
  }

  Future<void> select(String id, {String? bookId}) => _enqueue(() async {
    final choices = [...ReadingBackground.presets, ...await customImages()];
    if (!choices.any((e) => e.id == id)) throw StateError('背景已被删除');
    await _write(selectionKey, {'id': id}, bookId: bookId);
  });

  Future<void> _write(String key, Object json, {String? bookId}) => db
      .into(db.preferences)
      .insertOnConflictUpdate(
        PreferencesCompanion.insert(
          scope: bookId == null ? 'global' : 'book',
          scopeId: bookId ?? 'global',
          key: key,
          valueJson: jsonEncode(json),
          updatedAt: DateTime.now().toUtc(),
        ),
      );

  Future<void> _saveList(List<ReadingBackground> images) => _write(listKey, {
    'images': [
      for (final image in images) {'id': image.id, 'path': image.path},
    ],
  });

  Future<void> add(List<Uint8List> images) => _enqueue(() async {
    if (images.isEmpty) return;
    final release = await gate.enter();
    final created = <File>[];
    var committed = false;
    try {
      final old = await customImages();
      if (images.length + old.length > ReadingBackground.limit) {
        throw StateError('自定义背景最多导入9张');
      }
      final next = [...old];
      for (final bytes in images) {
        final id = const Uuid().v4(),
            path = 'reading-backgrounds/${const Uuid().v4()}.png';
        final file = File(p.join(root, path));
        created.add(file);
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes, flush: true);
        next.add(ReadingBackground(id, '', path: path));
      }
      await _saveList(next);
      committed = true;
    } finally {
      if (!committed) {
        for (final file in created) {
          if (await file.exists()) await file.delete();
        }
      }
      release();
    }
  });

  Future<void> remove(String id) => _enqueue(() async {
    final release = await gate.enter();
    try {
      final images = await customImages();
      final target = images.where((e) => e.id == id).firstOrNull;
      if (target == null) return;
      // 先在同一事务内更新名单及全部引用，再删除图片。其余图片保持稳定编号。
      await db.transaction(() async {
        await _saveList(images.where((e) => e.id != id).toList());
        final rows = await (db.select(
          db.preferences,
        )..where((t) => t.key.equals(selectionKey))).get();
        for (final row in rows) {
          if ((jsonDecode(row.valueJson) as Map)['id'] == id) {
            await _write(selectionKey, {
              'id': 'solid',
            }, bookId: row.scope == 'book' ? row.scopeId : null);
          }
        }
      });
      final file = File(p.join(root, target.path!));
      if (await file.exists()) await file.delete();
    } finally {
      release();
    }
  });
}
