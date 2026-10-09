/// 书架仓库契约（纯 Dart，不引用 Flutter / drift）。
///
/// 数据库是业务数据的唯一事实来源，界面通过 [watchActiveBooks] 观察书架。
library;

import '../models/book.dart';
import '../models/book_document.dart';

/// 导入任务 journal 的一行记录，用于启动时回收孤儿文件。
class ImportJobRecord {
  const ImportJobRecord({
    required this.id,
    required this.stage,
    this.stagingPath,
    this.targetBookId,
  });

  final String id;
  final String stage;
  final String? stagingPath;
  final String? targetBookId;
}

/// 一次导入提交所需的全部数据。
///
/// [book] 的 `contentPath`/`coverPath` 为相对书籍目录的路径，
/// [chapters] 为扁平章节元数据。
class ImportCommit {
  const ImportCommit({required this.book, required this.chapters});

  final Book book;
  final List<Chapter> chapters;
}

abstract class BookRepository {
  /// 书架观察流：只包含 `active` 与 `contentMissing` 状态的书籍，
  /// 按导入时间倒序。
  Stream<List<Book>> watchActiveBooks();

  Future<Book?> findById(String id);

  /// 按阅读顺序取章节索引（`ordinal` 升序）。
  ///
  /// 只读 `chapters` 表，不读章节文件：书架的章内进度与阅读顺序都以数据库为准
  /// （设计文档 6.3）。正文由 [ChapterContentRepository] 按需读取。
  Future<List<Chapter>> chaptersOf(String bookId);

  /// 按来源身份查重（本地文件为完整路径 URI），包含已删除行以复用 bookId。
  /// 方法名沿用历史命名，不代表新导入仍计算文件摘要。
  Future<Book?> findByHash(String sourceHash);

  /// 提交一次导入：写入书籍与章节，同一事务内完成。
  ///
  /// 事务提交即是书籍在书架可见的标志（设计文档 6.1）。
  Future<void> commitImport(ImportCommit commit);

  /// 重新激活墓碑删除的书籍：复用原 bookId，替换元数据与章节。
  ///
  /// 阅读历史与笔记挂在 bookId 上，复用 ID 才能保留（设计文档 6.1）。
  Future<void> reactivateImport(ImportCommit commit);

  /// 标记正文文件缺失（启动恢复时使用）。
  Future<void> markContentMissing(Iterable<String> bookIds);

  /// 标记为墓碑删除：书籍从书架隐藏，但同一文件重新导入时复用这一行。
  Future<void> markRemoved(String bookId, DateTime deletedAt);

  /// 已删除（墓碑）的书籍，用于启动时回收残留文件。
  Future<List<Book>> deletedBooks();

  /// 清掉墓碑书籍残留的章节索引行（正文文件已删除，索引不该再留着）。
  ///
  /// 返回清掉的行数；用于启动恢复自愈历史数据。
  Future<int> purgeOrphanChapters();

  /// 写入/更新导入任务 journal。
  Future<void> upsertJob(ImportJobRecord job);

  Future<void> deleteJob(String jobId);

  /// 上次运行未结束的导入任务（stage 不是终态）。
  Future<List<ImportJobRecord>> pendingJobs();
}
