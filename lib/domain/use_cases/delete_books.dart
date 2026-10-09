/// 删除书籍用例（设计文档 2.1「书籍管理」/7.3）：
///
/// - 数据库先行：把书籍标成墓碑删除（`status=removed`），书架立即不再显示；
/// - 再删本地文件：源文件副本、解析后的正文与资源目录一起删掉；
/// - **保留 bookId**：同一个文件重新导入时复用这一行（`reactivateImport`），
///   后续版本的阅读进度、笔记、统计因为挂在 bookId 上而不会被丢弃；
/// - 文件删除失败不视为失败：墓碑已经生效，残留目录由下次启动回收。
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
  });

  final int deletedCount;

  /// 实际尝试删除的目录总大小（统计值，不保证全部释放成功）
  final int freedBytes;

  /// 文件删除失败的本数（下次启动会回收）
  final int failedCount;
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
    } finally { releaseFiles?.call(); }
  }

  Future<DeleteBooksResult> _delete(Iterable<String> bookIds, {required DateTime now}) async {
    var deleted = 0;
    var freed = 0;
    var failed = 0;
    for (final id in bookIds) {
      final book = await _books.findById(id);
      if (book == null) continue;
      final release = await prepareContentChange?.call(id);
      try {
        // 先把书籍从书架隐藏（数据库是可见性的唯一依据）
        await _books.markRemoved(id, now);
        deleted++;
        try {
          final dir = await _storage.bookDirectoryPath(id);
          freed += await _storage.directorySize(dir);
          await _storage.deleteRecursively(dir);
        } catch (_) {
          // 文件删不掉时留墓碑即可，残留目录由启动回收处理
          failed++;
        }
      } finally {
        release?.call();
      }
    }
    return DeleteBooksResult(
      deletedCount: deleted,
      freedBytes: freed,
      failedCount: failed,
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
