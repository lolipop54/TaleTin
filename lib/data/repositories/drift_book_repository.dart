/// [BookRepository] 的 drift 实现。
///
/// 一份导入在同一事务里写书籍与章节：事务提交即书架可见
/// （设计文档 6.1），避免出现只有书名没有正文的半本书。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:drift/drift.dart';
import 'package:path/path.dart' as p;

import '../../domain/models/book.dart';
import '../../domain/models/book_document.dart';
import '../../domain/repositories/book_repository.dart';
import '../../engine/parsers/epub/epub_parser.dart';
import '../database/app_database.dart';
import '../mappers/book_mapper.dart';
import '../services/book_source_path.dart';
import '../services/book_source_availability.dart';

// 独立函数限定闭包捕获范围，避免同方法的数据库事务闭包让 this 随任务发送。
Future<Map<String, String>> _resolveLegacyTitlesInBackground(
  String source,
  List<Chapter> candidates,
) => Isolate.run(() => EpubParser.resolveLegacyTitles(source, candidates));

class DriftBookRepository implements BookRepository {
  DriftBookRepository(this._db, {this.libraryRoot});

  final AppDatabase _db;
  final String? libraryRoot;
  final _checkedTitles = <String>{};

  /// 书架观察流：墓碑删除的书籍不出现（设计文档 7.3），并带上阅读进度。
  ///
  /// 进度来自 `reading_positions`，所以那张表（以及章节索引）变化时也要重新发一次，
  /// 否则读完退回书架看到的还是旧百分比。
  @override
  Stream<List<Book>> watchActiveBooks() {
    final books = Stream<List<Book>>.multi((out) {
      Future<void> pending = Future.value();
      void refresh() {
        pending = pending
            .then((_) async => out.add(await _loadActiveBooks()))
            .catchError(
              (Object error, StackTrace stack) => out.addError(error, stack),
            );
      }

      // 完成记录是已读状态的事实来源，撤销已读同样刷新书架。
      final changes = _db
          .tableUpdates(
            TableUpdateQuery.allOf([
              for (final name in [
                'books',
                'chapters',
                'reading_positions',
                'preferences',
                'book_completions',
              ])
                TableUpdateQuery.onTableName(name),
            ]),
          )
          .listen((_) => refresh());
      refresh();
      out.onCancel = changes.cancel;
    });
    return watchBookSources(books);
  }

  Future<List<Book>> _loadActiveBooks() async {
    final query = _db.select(_db.books)
      ..where((t) => t.status.isNotValue(BookStatus.removed.code))
      ..orderBy([
        (t) => OrderingTerm.desc(t.importedAt),
        (t) => OrderingTerm.asc(t.title),
      ]);
    return _withChapterProgress(await query.get());
  }

  /// 补上阅读进度（设计文档 6.3）：优先用阅读位置里存的全书进度
  /// （逐页变化的精确值），早期没有该值的行退回「当前章之前的章节字数占比」。
  /// 没读过（没有 reading_positions 行）时保持 null = 未读。
  Future<List<Book>> _withChapterProgress(List<BookRow> rows) async {
    if (rows.isEmpty) return const [];
    final bookIds = [for (final row in rows) row.id];
    final positions = await (_db.select(
      _db.readingPositions,
    )..where((t) => t.bookId.isIn(bookIds))).get();
    final names =
        await (_db.select(_db.preferences)..where(
              (t) =>
                  t.scope.equals('book') &
                  t.key.equals('sourceFileName') &
                  t.scopeId.isIn(bookIds),
            ))
            .get();
    final nameOf = {
      for (final row in names) row.scopeId: jsonDecode(row.valueJson) as String,
    };
    final completed = await _db
        .customSelect(
          'SELECT DISTINCT book_id FROM book_completions WHERE revoked_at IS NULL',
        )
        .get();
    final finishedIds = {
      for (final row in completed) row.read<String>('book_id'),
    };
    final lastReadOf = {for (final row in positions) row.bookId: row.updatedAt};

    final chapterRows = await (_db.select(
      _db.chapters,
    )..where((t) => t.bookId.isIn(bookIds))).get();
    // bookId → (章节 ID → ordinal)、bookId → (ordinal → 该章之前的字数)
    final ordinalOf = <String, Map<String, int>>{};
    final readBefore = <String, Map<int, int>>{};
    for (final chapter in chapterRows) {
      (ordinalOf[chapter.bookId] ??= {})[chapter.id] = chapter.ordinal;
      final sum = readBefore[chapter.bookId] ??= {};
      sum[chapter.ordinal] = chapter.textLength;
    }
    for (final entry in readBefore.entries) {
      var running = 0;
      final ordinals = entry.value.keys.toList()..sort();
      for (final ordinal in ordinals) {
        final length = entry.value[ordinal]!;
        entry.value[ordinal] = running;
        running += length;
      }
    }

    final progressOf = <String, double>{};
    final chapterIdOf = <String, String?>{};
    for (final position in positions) {
      progressOf[position.bookId] = position.progress ?? 0;
      chapterIdOf[position.bookId] = _chapterIdOf(position.locatorJson);
    }

    return [
      for (final row in rows)
        _withProgress(
          bookFromRow(row).copyWith(
            finished: finishedIds.contains(row.id),
            lastReadAt: lastReadOf[row.id],
            sourceFileName: nameOf[row.id],
          ),
          storedProgress: progressOf[row.id],
          chapterId: chapterIdOf[row.id],
          ordinalOf: ordinalOf[row.id] ?? const {},
          readBefore: readBefore[row.id] ?? const {},
        ),
    ];
  }

  /// 进度百分比 0–100（两位小数由界面格式化）；算了半天算不出就返回原书
  Book _withProgress(
    Book book, {
    required double? storedProgress,
    required String? chapterId,
    required Map<String, int> ordinalOf,
    required Map<int, int> readBefore,
  }) {
    // 没有阅读位置的书保持“未读”，不能因为同书架其他书有进度就变成0%。
    if (book.lastReadAt == null || book.textLength <= 0) return book;
    if (storedProgress != null && storedProgress > 0) {
      return book.copyWith(
        readProgress: (storedProgress * 100).clamp(0.0, 100.0),
      );
    }
    // 没有精确进度（早期记录或刚翻开第一页）：按章边界给个下限估算
    if (chapterId == null) {
      // 位置存在但章节认不出来时，至少标成「在读」
      return book.copyWith(readProgress: storedProgress ?? 0);
    }
    final ordinal = ordinalOf[chapterId];
    if (ordinal == null) return book.copyWith(readProgress: 0);
    final read = readBefore[ordinal] ?? 0;
    return book.copyWith(
      readProgress: (read * 100 / book.textLength).clamp(0.0, 100.0),
    );
  }

  /// 从位置 JSON 里取章节 ID；格式不认识时返回 null（按未读处理）
  String? _chapterIdOf(String locatorJson) {
    try {
      final decoded = jsonDecode(locatorJson);
      if (decoded is! Map<String, Object?>) return null;
      final chapterId = decoded['chapterId'];
      return chapterId is String && chapterId.isNotEmpty ? chapterId : null;
    } on FormatException {
      return null;
    }
  }

  @override
  Future<Book?> findById(String id) async {
    final row = await (_db.select(
      _db.books,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    return row == null ? null : checkBookSource(bookFromRow(row));
  }

  @override
  Future<List<Chapter>> chaptersOf(String bookId) async {
    final rows =
        await (_db.select(_db.chapters)
              ..where((t) => t.bookId.equals(bookId))
              ..orderBy([(t) => OrderingTerm.asc(t.ordinal)]))
            .get();
    final chapters = [for (final row in rows) chapterFromRow(row)];
    final root = libraryRoot;
    if (root == null || _checkedTitles.contains(bookId)) return chapters;
    final candidates = chapters
        .where((c) => c.title == '第 ${c.ordinal + 1} 章')
        .toList();
    if (candidates.isEmpty) return chapters;
    final book = await findById(bookId);
    final source = bookSourcePath(p.join(root, bookId), 'epub');
    if (book?.format != BookFormat.epub || !await File(source).exists()) {
      return chapters;
    }
    // 回查在后台完成，只改标题，不重建正文或改变阅读位置的章节 ID。
    final titles = await _resolveLegacyTitlesInBackground(source, candidates);
    await _db.transaction(() async {
      for (final chapter in candidates) {
        final title = titles[chapter.id]!;
        if (title == chapter.title) continue;
        await (_db.update(_db.chapters)
              ..where((t) => t.bookId.equals(bookId) & t.id.equals(chapter.id)))
            .write(ChaptersCompanion(title: Value(title)));
      }
    });
    _checkedTitles.add(bookId);
    return [
      for (final chapter in chapters)
        Chapter(
          id: chapter.id,
          ordinal: chapter.ordinal,
          title: titles[chapter.id] ?? chapter.title,
          contentPath: chapter.contentPath,
          textLength: chapter.textLength,
          href: chapter.href,
        ),
    ];
  }

  @override
  Future<Book?> findByHash(String sourceHash) async {
    final row = await (_db.select(
      _db.books,
    )..where((t) => t.sourceHash.equals(sourceHash))).getSingleOrNull();
    return row == null ? null : bookFromRow(row);
  }

  /// 新增导入：书籍 + 章节一次事务写入。
  @override
  Future<void> commitImport(ImportCommit commit) => _db.transaction(() async {
    await _db.into(_db.books).insert(bookToCompanion(commit.book));
    if (commit.book.sourceFileName != null) {
      await _db
          .into(_db.preferences)
          .insertOnConflictUpdate(
            PreferencesCompanion.insert(
              scope: 'book',
              scopeId: commit.book.id,
              key: 'sourceFileName',
              valueJson: jsonEncode(commit.book.sourceFileName),
              updatedAt: DateTime.now().toUtc(),
            ),
          );
    }
    await _insertChapters(commit);
  });

  /// 复用已删除书籍的 bookId 重新激活：覆盖元数据并替换全部章节。
  @override
  Future<void> reactivateImport(ImportCommit commit) =>
      _db.transaction(() async {
        await (_db.update(_db.books)..where((t) => t.id.equals(commit.book.id)))
            .write(bookToCompanion(commit.book));
        await (_db.delete(
          _db.chapters,
        )..where((t) => t.bookId.equals(commit.book.id))).go();
        if (commit.book.sourceFileName != null) {
          await _db
              .into(_db.preferences)
              .insertOnConflictUpdate(
                PreferencesCompanion.insert(
                  scope: 'book',
                  scopeId: commit.book.id,
                  key: 'sourceFileName',
                  valueJson: jsonEncode(commit.book.sourceFileName),
                  updatedAt: DateTime.now().toUtc(),
                ),
              );
        }
        await _insertChapters(commit);
      });

  @override
  Future<void> markContentMissing(Iterable<String> bookIds) async {
    final ids = bookIds.toList();
    if (ids.isEmpty) return;
    await (_db.update(_db.books)..where((t) => t.id.isIn(ids))).write(
      const BooksCompanion(status: Value('contentMissing')),
    );
  }

  /// 标记墓碑删除，并清掉该书的章节索引行。
  ///
  /// 正文文件已经删除，索引行再留着就会指向不存在的文件；
  /// 书籍行保留是为了重新导入同一文件时复用 bookId（阅读进度、笔记挂在它上面）。
  @override
  Future<void> markRemoved(String bookId, DateTime deletedAt) =>
      _db.transaction(() async {
        await (_db.update(_db.books)..where((t) => t.id.equals(bookId))).write(
          BooksCompanion(
            status: Value(BookStatus.removed.code),
            deletedAt: Value(deletedAt),
          ),
        );
        await (_db.delete(
          _db.chapters,
        )..where((t) => t.bookId.equals(bookId))).go();
      });

  @override
  Future<List<Book>> deletedBooks() async {
    final rows = await (_db.select(
      _db.books,
    )..where((t) => t.status.equals(BookStatus.removed.code))).get();
    return [for (final row in rows) bookFromRow(row)];
  }

  @override
  Future<int> purgeOrphanChapters() {
    return _db.customUpdate(
      'DELETE FROM chapters WHERE book_id IN '
      "(SELECT id FROM books WHERE status = ?)",
      variables: [Variable.withString(BookStatus.removed.code)],
      updates: {_db.chapters},
    );
  }

  @override
  Future<void> upsertJob(ImportJobRecord job) => _db
      .into(_db.importJobs)
      .insertOnConflictUpdate(
        ImportJobsCompanion.insert(
          id: job.id,
          stage: job.stage,
          stagingPath: Value(job.stagingPath),
          targetBookId: Value(job.targetBookId),
          updatedAt: DateTime.now().toUtc(),
        ),
      );

  @override
  Future<void> deleteJob(String jobId) =>
      (_db.delete(_db.importJobs)..where((t) => t.id.equals(jobId))).go();

  @override
  Future<List<ImportJobRecord>> pendingJobs() async {
    final rows = await _db.select(_db.importJobs).get();
    return [
      for (final row in rows)
        ImportJobRecord(
          id: row.id,
          stage: row.stage,
          stagingPath: row.stagingPath,
          targetBookId: row.targetBookId,
        ),
    ];
  }

  Future<void> _insertChapters(ImportCommit commit) async {
    if (commit.chapters.isEmpty) return;
    await _db.batch((batch) {
      batch.insertAll(_db.chapters, [
        for (final c in commit.chapters) chapterToCompanion(commit.book.id, c),
      ]);
    });
  }
}
