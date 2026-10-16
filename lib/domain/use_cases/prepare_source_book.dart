import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/diagnostics/reader_work_trace.dart';

import '../models/book.dart';
import '../models/import_job.dart';
import '../repositories/book_repository.dart';
import '../services/document_platform.dart';
import 'import_books.dart';

/// 开书和阅读中刷新共用一次更新；解析完整提交后才允许继续读取。
class PrepareSourceBook {
  PrepareSourceBook(
    this.books,
    this.importer,
    this.sourcePath, {
    this.needsPreparation,
    this.txtChoice,
  });
  final BookRepository books;
  final ImportBooksUseCase importer;
  final Future<String> Function(Book) sourcePath;
  final Future<bool> Function(Book)? needsPreparation;
  final Future<TxtImportChoice?> Function(Book)? txtChoice;
  final _pending = <String, Future<Book>>{};

  Future<Book> call(String id) => _pending.putIfAbsent(
    id,
    () => traceReaderWork('source.prepare', () => _prepare(id), {'bookId': id})
        .whenComplete(() {
          _pending.remove(id);
        }),
  );

  Future<Book> _prepare(String id) async {
    var book = await books.findById(id);
    if (book != null) {
      // 显式重新解析也可能正在发布文件；等同一任务完成后再看新索引和数据库。
      final pending = importer.pendingForBook(book);
      if (pending != null) {
        final result = await traceReaderWork(
          'source.wait_pending_import',
          () => pending,
          {'bookId': id},
        );
        if (result.stage != ImportStage.done &&
            result.stage != ImportStage.duplicate) {
          throw result.failure ?? StateError('书籍准备失败');
        }
        book = await books.findById(id);
      }
    }
    if (book == null || book.status == BookStatus.removed) {
      throw StateError('这本书已不在书架中');
    }
    if (book.status == BookStatus.contentMissing) return book;
    if (book.status != BookStatus.sourceChanged &&
        book.status != BookStatus.preparing &&
        await needsPreparation?.call(book) != true) {
      return book;
    }
    final file = File(await sourcePath(book));
    final result = await importer.importOne(
      PickedDocument(
        uri: file.uri.toString(),
        name: book.sourceFileName ?? p.basename(file.path),
        sizeBytes: await file.length(),
      ),
      onProgress: (_) {},
      cancel: CancelToken(),
      reparse: true,
      replaceBookId: id,
      onlyIfPresent: true,
      priority: true,
      txtChoice: await txtChoice?.call(book),
    );
    if (result.stage != ImportStage.done) {
      throw result.failure ?? StateError('更新失败，请重试');
    }
    final updated = await books.findById(id);
    if (updated == null || updated.status != BookStatus.active) {
      throw StateError('源文件仍在修改，请稍后重试');
    }
    return updated;
  }
}
