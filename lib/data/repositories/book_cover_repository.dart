import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../../domain/models/book_cover_choice.dart';
import '../../domain/models/book.dart';
import '../../domain/repositories/book_cover_repository.dart';
import '../../domain/services/library_file_gate.dart';
import '../database/app_database.dart';

/// 已导入的图片共用一个图库，单书和格式只保存各自选中的封面。
class DriftBookCoverRepository implements BookCoverRepository {
  DriftBookCoverRepository(this.db, this.root, this.gate);
  final AppDatabase db;
  final String root;
  final LibraryFileGate gate;
  static const preferenceKey = 'customCover';
  static const _gallery = BookCoverChoice.galleryDirectory;
  static const _galleryLock = ':cover-gallery';
  static const _migrationKey = 'coverGalleryMigrated';
  static final _imageName = RegExp(r'^[a-zA-Z0-9-]+\.png$');

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
  Future<Map<String, BookCoverChoice>> loadBooks(Iterable<String> ids) =>
      load(db, ids);

  @override
  Future<void> prepareGallery() async {
    final release = await gate.enter();
    final unlock = await gate.enterBook(_galleryLock);
    try {
      await _migrateLegacyGallery();
    } finally {
      unlock();
      release();
    }
  }

  @override
  Future<List<String>> images() async {
    final release = await gate.enter();
    final unlock = await gate.enterBook(_galleryLock);
    try {
      await _migrateLegacyGallery();
      final paths = await _listImages(_gallery)
          .map((file) => '$_gallery/${p.basename(file.path)}')
          .toList();
      return paths..sort();
    } finally {
      unlock();
      release();
    }
  }

  Stream<File> _listImages(String folder) async* {
    final directory = Directory(p.join(root, folder));
    if (!await directory.exists()) return;
    await for (final entry in directory.list(followLinks: false)) {
      if (entry is File && _imageName.hasMatch(p.basename(entry.path))) {
        yield entry;
      }
    }
  }

  @override
  Future<List<String>> addImages(Stream<Uint8List> images) async {
    final release = await gate.enter();
    final unlock = await gate.enterBook(_galleryLock);
    final directory = Directory(p.join(root, _gallery));
    final saved = <String>[];
    File? pending;
    try {
      final batch = DateTime.now().microsecondsSinceEpoch;
      final id = const Uuid().v4();
      await for (final bytes in images) {
        final index = saved.length.toString().padLeft(8, '0');
        final name = 'import-$batch-$id-$index.png';
        await directory.create(recursive: true);
        pending = File(p.join(directory.path, '$name.part'));
        await pending.writeAsBytes(bytes, flush: true);
        await pending.rename(p.join(directory.path, name));
        pending = null;
        saved.add('$_gallery/$name');
      }
      return saved;
    } catch (_) {
      if (pending != null) await _remove(pending);
      for (final path in saved) {
        await _remove(File(p.join(root, path)));
      }
      rethrow;
    } finally {
      unlock();
      release();
    }
  }

  File _galleryFile(String path) {
    final name = p.posix.basename(path);
    if (path != '$_gallery/$name' || !_imageName.hasMatch(name)) {
      throw const FormatException('自定义封面路径无效');
    }
    return File(p.join(root, path));
  }

  Future<String?> _checkedImage(String? path) async {
    if (path == null) return null;
    if (await FileSystemEntity.type(
          _galleryFile(path).path,
          followLinks: false,
        ) !=
        FileSystemEntityType.file) {
      throw const FormatException('找不到选中的封面图片');
    }
    return path;
  }

  @override
  Future<void> removeImage(String path) async {
    final file = _galleryFile(path);
    final release = await gate.enter();
    final unlock = await gate.enterBook(_galleryLock);
    try {
      // 先撤销所有引用，避免书架和备份读到已删除的图片。
      final settings = db.preferences;
      await db.transaction(() async {
        final rows =
            await (db.select(settings)..where(
                  (t) =>
                      (t.scope.equals('book') & t.key.equals(preferenceKey)) |
                      (t.scope.equals('global') &
                          t.key.isIn([
                            for (final format in BookFormat.values)
                              '$preferenceKey:${format.code}',
                          ])),
                ))
                .get();
        for (final row in rows) {
          final choice = BookCoverChoice.fromJson(
            jsonDecode(row.valueJson) as Map<String, dynamic>,
          );
          if (choice.imagePath != path) continue;
          await (db.delete(settings)..where(
                (t) =>
                    t.scope.equals(row.scope) &
                    t.scopeId.equals(row.scopeId) &
                    t.key.equals(row.key),
              ))
              .go();
        }
      });
      if (await file.exists()) await file.delete();
    } finally {
      unlock();
      release();
    }
  }

  @override
  Future<void> saveGlobal(
    BookFormat format, {
    BookCoverPreset? preset,
    Uint8List? image,
    String? existingImage,
  }) async {
    final release = await gate.enter();
    final unlockGallery = await gate.enterBook(_galleryLock);
    final unlock = await gate.enterBook('global-cover-${format.code}');
    File? created;
    var committed = false;
    try {
      var relative = await _checkedImage(existingImage);
      if (image != null) {
        relative = '$_gallery/${const Uuid().v4()}.png';
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
    } finally {
      if (!committed && created != null) await _remove(created);
      unlock();
      unlockGallery();
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
    String? existingImage,
  }) async {
    final release = await gate.enter();
    final unlockGallery = await gate.enterBook(_galleryLock);
    final locks = <void Function()>[];
    File? created;
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
      var relative = await _checkedImage(existingImage);
      if (image != null && selected.isNotEmpty) {
        relative = '$_gallery/${const Uuid().v4()}.png';
        created = File(p.join(root, relative));
        await created.parent.create(recursive: true);
        await created.writeAsBytes(image, flush: true);
      }
      // 空选择也保留，明确选择原书封面时不能再被全局设置覆盖。
      final choice = BookCoverChoice(preset: preset, imagePath: relative);
      await db.transaction(() async {
        for (final id in selected) {
          await db
              .into(db.preferences)
              .insertOnConflictUpdate(
                PreferencesCompanion.insert(
                  scope: 'book',
                  scopeId: id,
                  key: preferenceKey,
                  valueJson: jsonEncode(choice.toJson()),
                  updatedAt: DateTime.now().toUtc(),
                ),
              );
        }
      });
      committed = true;
    } finally {
      if (!committed && created != null) await _remove(created);
      for (final unlock in locks.reversed) {
        unlock();
      }
      unlockGallery();
      release();
    }
  }

  /// 打开图库时合并旧版目录。每张图使用稳定的新路径，失败重试不会重复导入。
  /// 先复制文件，再更新引用，最后删除旧文件，期间备份和删书等待对应的锁。
  Future<void> _migrateLegacyGallery() async {
    final settings = db.preferences;
    final migrated =
        await (db.select(settings)..where(
              (t) =>
                  t.scope.equals('global') &
                  t.scopeId.equals('') &
                  t.key.equals(_migrationKey),
            ))
            .getSingleOrNull();
    if (migrated != null) return;

    final ids = await (db.selectOnly(
      db.books,
    )..addColumns([db.books.id])).get();
    for (final row in ids) {
      final id = row.read(db.books.id)!;
      await _mergeLegacyScope('book', id, preferenceKey, '$id/covers', id);
    }
    for (final format in BookFormat.values) {
      await _mergeLegacyScope(
        'global',
        '',
        '$preferenceKey:${format.code}',
        'global-covers/${format.code}',
        'global-cover-${format.code}',
      );
    }
    await db
        .into(settings)
        .insertOnConflictUpdate(
          PreferencesCompanion.insert(
            scope: 'global',
            scopeId: '',
            key: _migrationKey,
            valueJson: 'true',
            updatedAt: DateTime.now().toUtc(),
          ),
        );
  }

  Future<void> _mergeLegacyScope(
    String scope,
    String scopeId,
    String key,
    String folder,
    String lockId,
  ) async {
    final unlock = await gate.enterBook(lockId);
    try {
      final sources = await _listImages(folder).toList();
      if (sources.isEmpty) return;
      Expression<bool> sameRow($PreferencesTable t) =>
          t.scope.equals(scope) & t.scopeId.equals(scopeId) & t.key.equals(key);
      final row = await (db.select(
        db.preferences,
      )..where(sameRow)).getSingleOrNull();
      final choice = row == null
          ? null
          : BookCoverChoice.fromJson(
              jsonDecode(row.valueJson) as Map<String, dynamic>,
            );
      final selected = choice?.imagePath;
      final selectedSource = selected == null
          ? null
          : BookCoverChoice.libraryImagePath(selected, scopeId);
      final gallery = Directory(p.join(root, _gallery));
      await gallery.create(recursive: true);
      String? selectedTarget;
      for (final source in sources) {
        final original = '$folder/${p.basename(source.path)}';
        final name = 'import-0-${sha256.convert(utf8.encode(original))}.png';
        final target = File(p.join(gallery.path, name));
        if (!await target.exists()) {
          final pending = File('${target.path}.part');
          try {
            await source.copy(pending.path);
            await pending.rename(target.path);
          } finally {
            await _remove(pending);
          }
        }
        if (selectedSource == original) selectedTarget = '$_gallery/$name';
      }
      if (selectedTarget != null) {
        await (db.update(db.preferences)..where(sameRow)).write(
          PreferencesCompanion(
            valueJson: Value(
              jsonEncode(
                BookCoverChoice(
                  preset: choice?.preset,
                  imagePath: selectedTarget,
                ).toJson(),
              ),
            ),
          ),
        );
      }
      for (final source in sources) {
        await _remove(source);
      }
    } finally {
      unlock();
    }
  }

  Future<void> _remove(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      /* 清理失败留待书库文件清理处理。 */
    }
  }
}
