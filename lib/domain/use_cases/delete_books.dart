/// 删除书籍用例（设计文档 2.1「书籍管理」/7.3）：
///
/// - 数据库先行：事务中删除书籍及位置、笔记、设置、统计等关联数据；
/// - 再删本地文件：源文件副本、解析后的正文与资源目录一起删掉；
/// - 重新导入按全新书籍处理，不复用旧 bookId 或阅读资料；
/// - 文件清理失败只暂存清理任务ID，启动恢复继续清理，成功后移除任务。
library;

import '../services/library_file_gate.dart';

import '../repositories/book_repository.dart';
import '../services/import_storage.dart';
import '../services/book_content_change.dart';

/// 删除结果，用于界面提示删掉了多少、释放了多少空间。
class DeleteBooksResult {
  const DeleteBooksResult({
    required this.deletedCount,
    required this.freedBytes,
    required this.failedCount,
    this.undeletedIds = const {},
  });

  final int deletedCount;

  /// 已确认删除成功的文件字节数，不把旧估计或失败文件算作释放。
  final int freedBytes;

  /// 准备交接、数据库删除或文件清理失败的书籍数。
  final int failedCount;

  /// 数据库删除失败的书籍仍留在书架，供界面保留选择并允许重试。
  final Set<String> undeletedIds;
}

class DeleteBooks {
  /// 构造参数用私有命名形参：调用方写 `books:` / `storage:`。
  DeleteBooks({
    required this._books,
    required this._storage,
    this.prepareContentChange,
    this.fileGate,
  });
  final PrepareBookContentChange? prepareContentChange;
  final LibraryFileGate? fileGate;

  final BookRepository _books;
  final ImportStorage _storage;

  /// 预估这批书占用的空间，供删除确认弹窗展示。
  Future<int> estimateSize(Iterable<String> bookIds) async {
    var total = 0;
    for (final id in bookIds) {
      total += await _storage.directorySize(
        await _storage.bookDirectoryPath(id),
      );
    }
    return total;
  }

  /// 执行删除：逐本独立处理，单本失败不影响其他书。
  Future<DeleteBooksResult> run(
    Iterable<String> bookIds, {
    required DateTime now,
  }) async {
    final releaseFiles = await fileGate?.enter();
    try {
      return await _delete(bookIds, now: now);
    } finally {
      releaseFiles?.call();
    }
  }

  Future<DeleteBooksResult> _delete(
    Iterable<String> bookIds, {
    required DateTime now,
  }) async {
    var deleted = 0;
    var freed = 0;
    var failed = 0;
    final undeleted = <String>{};
    final releases = <void Function()>[];
    final ready = <String>[];
    // Stable ordering prevents two overlapping delete commands holding opposite locks.
    final ids = bookIds.toSet().toList()..sort();
    try {
      for (final id in ids) {
        final releaseBook = await fileGate?.enterBook(id);
        if (releaseBook != null) releases.add(releaseBook);
      }
      final existing = await _books.existingIds(ids);
      for (final id in ids) {
        try {
          if (!existing.contains(id)) continue;
          final release = await prepareContentChange?.call(id);
          if (release != null) releases.add(release);
          ready.add(id);
        } catch (_) {
          failed++;
          undeleted.add(id);
        }
      }
      Set<String> rejected;
      try {
        rejected = await _books.markRemovedMany(ready, now);
      } catch (_) {
        rejected = ready.toSet();
      }
      failed += rejected.length;
      undeleted.addAll(rejected);
      for (final id in ready.where((id) => !rejected.contains(id))) {
        deleted++;
        try {
          final dir = await _storage.bookDirectoryPath(id);
          final result = await _storage.deleteRecursivelyWithSize(dir);
          freed += result.freedBytes;
          if (result.failed) {
            failed++;
          } else {
            await _books.deleteJob('delete:$id');
          }
        } catch (_) {
          failed++;
        }
      }
    } finally {
      for (final release in releases.reversed) {
        release();
      }
    }
    return DeleteBooksResult(
      deletedCount: deleted,
      freedBytes: freed,
      failedCount: failed,
      undeletedIds: Set.unmodifiable(undeleted),
    );
  }
}

/// 字节数 → 「12.4 MB」。
String formatBytes(int bytes) {
  const unit = 1024;
  if (bytes < unit) return '$bytes B';
  if (bytes < unit * unit) return '${(bytes / unit).toStringAsFixed(1)} KB';
  if (bytes < unit * unit * unit) {
    return '${(bytes / unit / unit).toStringAsFixed(1)} MB';
  }
  return '${(bytes / unit / unit / unit).toStringAsFixed(2)} GB';
}
