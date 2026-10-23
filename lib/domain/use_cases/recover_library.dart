/// 启动恢复：回收上次运行留下的暂存文件，并核对书籍与文件是否对得上。
///
/// 文件移动与数据库提交不是同一事务（设计文档 6.1），因此启动时必须：
/// 1. 清掉 `cache/import/<jobId>` 残留（提交前的产物都在这里）；
/// 2. 清空 `import_jobs` 中未结束的任务记录；
/// 3. 继续删除任务，并兼容旧版已删除记录留下的书籍目录；
/// 4. 对比文件系统，把正文目录已经不在的书籍标记为 `contentMissing`，
///    避免书架上出现点开才发现没有正文的书籍。
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import '../repositories/book_repository.dart';
import '../models/book.dart';
import '../services/import_storage.dart';

/// 恢复结果，用于启动日志与调试。
class RecoveryReport {
  const RecoveryReport({
    required this.removedStagingDirs,
    required this.pendingJobs,
    required this.contentMissingBooks,
    this.removedBookDirs = 0,
    this.releasedTxtBytes = 0,
  });

  final int removedStagingDirs;
  final int pendingJobs;
  final int contentMissingBooks;

  /// 清掉的删除任务／旧版已删除书籍残留目录数量
  final int removedBookDirs;
  final int releasedTxtBytes;

  static const empty = RecoveryReport(
    removedStagingDirs: 0,
    pendingJobs: 0,
    contentMissingBooks: 0,
    removedBookDirs: 0,
  );
}

class RecoverLibrary {
  RecoverLibrary({required this.books, required this.storage});

  final BookRepository books;
  final ImportStorage storage;

  Future<RecoveryReport> run() async {
    final jobs = await books.pendingJobs();
    final removedStaging = await storage.cleanupStaging(
      keepJobIds: const <String>[],
    );
    // 墓碑书籍的残留目录与章节索引回收（删除时没清干净的兜底）
    var removedBookDirs = 0;
    for (final job in jobs) {
      if (job.stage == 'deleting' && job.targetBookId != null) {
        final directory = await storage.bookDirectoryPath(job.targetBookId!);
        if (Directory(directory).existsSync()) {
          await storage.deleteRecursively(directory);
          removedBookDirs++;
        }
      }
      await books.deleteJob(job.id);
    }
    for (final book in await books.deletedBooks()) {
      final dir = await storage.bookDirectoryPath(book.id);
      if (!Directory(dir).existsSync()) continue;
      await storage.deleteRecursively(dir);
      removedBookDirs++;
    }
    await books.purgeOrphanChapters();

    final libraryBooks = await books.watchActiveBooks().first;
    final missing = <String>[];
    var releasedTxtBytes = 0;
    for (final book in libraryBooks) {
      // 已保存来源、尚未完成目录的书在重启后仍可开书准备，不能标成正文丢失。
      if (book.status == BookStatus.preparing) continue;
      final content = p.join(
        await storage.bookDirectory(book.id),
        'content',
        '${book.contentVersion}',
      );
      final manifestMissing = !File(p.join(content, 'manifest.json'))
          .existsSync();
      if (manifestMissing) missing.add(book.id);
      if (!manifestMissing &&
          book.format == BookFormat.txt &&
          File(p.join(content, 'text.txt')).existsSync()) {
        releasedTxtBytes += await storage.removeRedundantTxtCopy(
          book.id,
          book.contentVersion,
          await books.chaptersOf(book.id),
        );
      }
    }
    if (missing.isNotEmpty) {
      await books.markContentMissing(missing);
    }

    return RecoveryReport(
      removedStagingDirs: removedStaging,
      pendingJobs: jobs.length,
      contentMissingBooks: missing.length,
      removedBookDirs: removedBookDirs,
      releasedTxtBytes: releasedTxtBytes,
    );
  }
}
