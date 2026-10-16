/// [ImportStorage] 的本地文件实现。
///
/// 目录布局（设计文档第 5 节）：
/// - `files/library/<bookId>/source.<ext>`
/// - `files/library/<bookId>/content/<版本>/`
/// - `cache/import/<jobId>/` 导入暂存，提交或失败后删除
library;

import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/errors/import_error.dart';
import '../../domain/services/import_storage.dart';
import '../../domain/models/book_document.dart';
import 'remove_redundant_txt_copy.dart' as txt_cleanup;

class FileImportStorage implements ImportStorage {
  FileImportStorage({Directory? libraryRoot, Directory? cacheRoot})
    : _libraryOverride = libraryRoot,
      _cacheOverride = cacheRoot;

  final Directory? _libraryOverride;
  final Directory? _cacheOverride;

  Directory? _libraryRoot;
  Directory? _stagingRoot;

  /// `files/library`
  Future<Directory> libraryRoot() async {
    final cached = _libraryRoot;
    if (cached != null) return cached;
    final base = _libraryOverride ?? await getApplicationSupportDirectory();
    final dir = Directory(p.join(base.path, 'library'));
    await dir.create(recursive: true);
    return _libraryRoot = dir;
  }

  /// `cache/import`
  Future<Directory> stagingRoot() async {
    final cached = _stagingRoot;
    if (cached != null) return cached;
    final base = _cacheOverride ?? await getApplicationCacheDirectory();
    final dir = Directory(p.join(base.path, 'import'));
    await dir.create(recursive: true);
    return _stagingRoot = dir;
  }

  @override
  Future<String> bookDirectoryPath(String bookId) async {
    final root = await libraryRoot();
    return p.join(root.path, bookId);
  }

  @override
  Future<int> removeRedundantTxtCopy(
    String bookId,
    int contentVersion,
    List<Chapter> chapters,
  ) async {
    final directory = await bookDirectoryPath(bookId);
    return Isolate.run(
      () => txt_cleanup.removeRedundantTxtCopy(
        directory,
        contentVersion,
        chapters,
      ),
    );
  }

  @override
  Future<int> directorySize(String path) async {
    final dir = Directory(path);
    if (!await dir.exists()) return 0;
    var total = 0;
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      try {
        total += await entity.length();
      } on FileSystemException {
        // 统计失败不影响删除：按 0 计
      }
    }
    return total;
  }

  @override
  Future<StorageDeletion> deleteRecursivelyWithSize(String path) =>
      Isolate.run(() => _deleteAndCount(path));

  @override
  Future<String> bookDirectory(String bookId) async {
    final root = await libraryRoot();
    final dir = Directory(p.join(root.path, bookId));
    await dir.create(recursive: true);
    return dir.path;
  }

  @override
  Future<String> stagingDirectory(String jobId) async {
    final root = await stagingRoot();
    final dir = Directory(p.join(root.path, jobId));
    await dir.create(recursive: true);
    return dir.path;
  }

  @override
  Future<void> ensureDirectory(String path) =>
      Directory(path).create(recursive: true);

  /// 分块写入平台文档流；去重由来源路径负责，不计算内容摘要。
  ///
  /// 单个哈希器贯穿整个文件，避免大文件整本进内存。
  @override
  Future<CopiedFile> copyStream({
    required String targetPath,
    required Future<List<int>?> Function() readChunk,
    required void Function(int copiedBytes) onProgress,
    required bool Function() isCancelled,
  }) async {
    final file = File(targetPath);
    await file.parent.create(recursive: true);
    final handle = await file.open(mode: FileMode.writeOnly);
    var total = 0;
    try {
      while (true) {
        if (isCancelled()) {
          throw const ImportFailure(ImportErrorCode.cancelled);
        }
        final chunk = await readChunk();
        if (chunk == null || chunk.isEmpty) break;
        await handle.writeFrom(chunk);
        total += chunk.length;
        onProgress(total);
      }
    } finally {
      await handle.close();
    }
    return CopiedFile(
      byteCount: total,
      sha256Hex: '', // 保留旧接口字段；来源身份由导入入口按URI确定。
    );
  }

  @override
  Future<void> writeBytes(String path, List<int> bytes) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes, flush: true);
  }

  /// 同卷重命名：要么完整出现，要么完全不存在，不产生半本可见书籍。
  @override
  Future<void> move({required String from, required String to}) async {
    final source = Directory(from);
    if (!await source.exists()) {
      // 源也可能是文件（当前流水线只移动目录）
      await File(from).rename(to);
      return;
    }
    await source.rename(to);
  }

  @override
  Future<void> deleteRecursively(String path) async {
    final dir = Directory(path);
    if (await dir.exists()) {
      await dir.delete(recursive: true);
      return;
    }
    final file = File(path);
    if (await file.exists()) await file.delete();
  }

  @override
  Future<int> cleanupStaging({required Iterable<String> keepJobIds}) async {
    final root = await stagingRoot();
    final keep = keepJobIds.toSet();
    var removed = 0;
    if (!await root.exists()) return 0;
    await for (final entity in root.list()) {
      final name = p.basename(entity.path);
      if (keep.contains(name)) continue;
      if (entity is Directory) {
        await entity.delete(recursive: true);
        removed++;
      }
    }
    return removed;
  }
}

// Only the supplied private book tree is visited. Links are removed as links,
// never followed to a shared-storage source. Work runs outside the UI isolate.
StorageDeletion _deleteAndCount(String path) {
  var freed = 0;
  var failed = false;
  void remove(String current) {
    try {
      final type = FileSystemEntity.typeSync(current, followLinks: false);
      if (type == FileSystemEntityType.notFound) return;
      if (type == FileSystemEntityType.link) {
        Link(current).deleteSync();
      } else if (type == FileSystemEntityType.directory) {
        for (final child in Directory(current).listSync(followLinks: false)) {
          remove(child.path);
        }
        Directory(current).deleteSync();
      } else {
        final file = File(current);
        final bytes = file.lengthSync();
        file.deleteSync();
        freed += bytes;
      }
    } on FileSystemException {
      failed = true;
    }
  }

  remove(path);
  return StorageDeletion(freedBytes: freed, failed: failed);
}
