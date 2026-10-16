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
import '../services/book_source_integrity.dart';
import '../services/source_position_preparation.dart';

// 独立函数限定闭包捕获范围，避免同方法的数据库事务闭包让 this 随任务发送。
Future<Map<String, String>> _resolveLegacyTitlesInBackground(
  String source,
  List<Chapter> candidates,
) => Isolate.run(() => EpubParser.resolveLegacyTitles(source, candidates));

class DriftBookRepository implements BookRepository {
  DriftBookRepository(this._db, {this.libraryRoot});

  final AppDatabase _db;
  final String? libraryRoot;
  late final _sourceIntegrity = BookSourceIntegrity(libraryRoot);
  final _checkedTitles = <String>{};

  @override
  Future<Set<String>> existingIds(Iterable<String> ids) async {
    final selected = ids.toSet().toList();
    final found = <String>{};
    // Stay below the parameter limit even for a large multi-selection.
    for (var start = 0; start < selected.length; start += 512) {
      final query = _db.selectOnly(_db.books)
        ..addColumns([_db.books.id])
        ..where(_db.books.id.isIn(selected.skip(start).take(512)));
      found.addAll((await query.get()).map((r) => r.read(_db.books.id)!));
    }
    return found;
  }

  /// 书架观察流：墓碑删除的书籍不出现（设计文档 7.3），并带上阅读进度。
  ///
  /// 进度来自 `reading_positions`，所以那张表变化时也要重新发一次，
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
    return watchBookSources(books, checkSource: _sourceIntegrity.check);
  }

  Future<List<Book>> _loadActiveBooks() async {
    final query = _db.select(_db.books)
      ..where((t) => t.status.isNotValue(BookStatus.removed.code))
      ..orderBy([
        (t) => OrderingTerm.desc(t.importedAt),
        (t) => OrderingTerm.asc(t.title),
      ]);
    return _withReadingProgress(await query.get());
  }

  /// 补上阅读进度（设计文档 6.3）：直接使用阅读位置里存的全书进度。
  /// 对外发布版本均已保存精确比例，0 也是有效值，不再按章节估算。
  /// 没读过（没有 reading_positions 行）时保持 null = 未读。
  Future<List<Book>> _withReadingProgress(List<BookRow> rows) async {
    if (rows.isEmpty) return const [];
    final bookIds = [for (final row in rows) row.id];
    final positionTable = _db.readingPositions;
    // 翻页会刷新后台书架；只取比例和时间，不读取章节或传回位置 JSON。
    final positions =
        await (_db.selectOnly(positionTable)
              ..addColumns([
                positionTable.bookId,
                positionTable.progress,
                positionTable.updatedAt,
              ])
              ..where(positionTable.bookId.isIn(bookIds)))
            .get();
    final positionOf = {
      for (final row in positions)
        row.read(positionTable.bookId)!: (
          progress: ((row.read(positionTable.progress) ?? 0) * 100).clamp(
            0.0,
            100.0,
          ),
          updatedAt: row.read(positionTable.updatedAt)!,
        ),
    };
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
    return [
      for (final row in rows)
        bookFromRow(row).copyWith(
          finished: finishedIds.contains(row.id),
          lastReadAt: positionOf[row.id]?.updatedAt,
          readProgress: positionOf[row.id]?.progress,
          sourceFileName: nameOf[row.id],
        ),
    ];
  }

  @override
  Future<Book?> findById(String id) async {
    final row = await (_db.select(
      _db.books,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    return row == null ? null : _sourceIntegrity.check(bookFromRow(row));
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
    await _savePositionProof(commit);
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
        if (commit.sourceChanged) {
          await _markLocationsForRelocation(commit.book.id);
        }
        await _savePositionProof(commit);
      });

  Future<void> _savePositionProof(ImportCommit commit) async {
    final proof = commit.positionProof;
    if (proof == null) return;
    await _db
        .into(_db.preferences)
        .insertOnConflictUpdate(
          PreferencesCompanion.insert(
            scope: 'book',
            scopeId: commit.book.id,
            key: sourcePositionProofKey,
            valueJson: jsonEncode(proof.toJson()),
            updatedAt: DateTime.now().toUtc(),
          ),
        );
  }

  /// 与新章节同一事务发布，防止中途退出后旧位置被当作新正文位置。
  Future<void> _markLocationsForRelocation(String bookId) async {
    String mark(String raw) {
      final value = jsonDecode(raw) as Map<String, dynamic>;
      value['needsRelocation'] = true;
      return jsonEncode(value);
    }

    final positions = await (_db.select(
      _db.readingPositions,
    )..where((t) => t.bookId.equals(bookId))).get();
    for (final row in positions) {
      // 新正文找不到原句时允许从起点阅读，但保留更新前最后确认的位置证据。
      if ((jsonDecode(row.locatorJson) as Map)['needsRelocation'] != true) {
        await _db
            .into(_db.preferences)
            .insertOnConflictUpdate(
              PreferencesCompanion.insert(
                scope: 'book',
                scopeId: bookId,
                key: 'sourcePreviousPosition',
                valueJson: jsonEncode({
                  'locator': jsonDecode(row.locatorJson),
                  'progress': row.progress,
                }),
                updatedAt: DateTime.now().toUtc(),
              ),
            );
      }
      await (_db.update(
        _db.readingPositions,
      )..where((t) => t.bookId.equals(bookId))).write(
        ReadingPositionsCompanion(locatorJson: Value(mark(row.locatorJson))),
      );
    }
    final notes = await (_db.select(
      _db.annotations,
    )..where((t) => t.bookId.equals(bookId))).get();
    for (final row in notes) {
      await (_db.update(
        _db.annotations,
      )..where((t) => t.id.equals(row.id))).write(
        AnnotationsCompanion(
          startLocatorJson: Value(mark(row.startLocatorJson)),
          endLocatorJson: row.endLocatorJson == null
              ? const Value.absent()
              : Value(mark(row.endLocatorJson!)),
        ),
      );
    }
    final drafts =
        await (_db.select(_db.preferences)..where(
              (t) =>
                  t.scope.equals('book') &
                  t.scopeId.equals(bookId) &
                  t.key.equals('noteDraft'),
            ))
            .get();
    for (final row in drafts) {
      final draft = jsonDecode(row.valueJson) as Map<String, dynamic>;
      for (final key in ['start', 'end']) {
        (draft[key] as Map<String, dynamic>)['needsRelocation'] = true;
      }
      await (_db.update(_db.preferences)..where(
            (t) =>
                t.scope.equals('book') &
                t.scopeId.equals(bookId) &
                t.key.equals('noteDraft'),
          ))
          .write(PreferencesCompanion(valueJson: Value(jsonEncode(draft))));
    }
  }

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
      _db.transaction(() => _writeRemoved(bookId, deletedAt));

  Future<void> _writeRemoved(String bookId, DateTime deletedAt) async {
    await (_db.update(_db.books)..where((t) => t.id.equals(bookId))).write(
      BooksCompanion(
        status: Value(BookStatus.removed.code),
        deletedAt: Value(deletedAt),
      ),
    );
    await (_db.delete(
      _db.chapters,
    )..where((t) => t.bookId.equals(bookId))).go();
  }

  @override
  Future<Set<String>> markRemovedMany(
    Iterable<String> ids,
    DateTime deletedAt,
  ) => _db.transaction(() async {
    final failed = <String>{};
    for (final id in ids) {
      // Keep writes in the outer Drift notification scope. An explicit SQLite
      // savepoint preserves per-book rollback without child stream notifications.
      await _db.customStatement('SAVEPOINT gt_delete_book');
      try {
        await _writeRemoved(id, deletedAt);
        await _db.customStatement('RELEASE SAVEPOINT gt_delete_book');
      } catch (_) {
        await _db.customStatement('ROLLBACK TO SAVEPOINT gt_delete_book');
        await _db.customStatement('RELEASE SAVEPOINT gt_delete_book');
        failed.add(id);
      }
    }
    return failed;
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
