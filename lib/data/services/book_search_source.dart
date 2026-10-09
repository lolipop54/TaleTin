import 'dart:convert';
import 'dart:async';

import 'package:crypto/crypto.dart';

import '../../domain/models/book.dart';
import '../../domain/models/book_document.dart';
import '../../domain/repositories/book_repository.dart';
import '../../domain/repositories/chapter_content_repository.dart';

/// 协调正文快照和逐章读取；文件更新前作废旧请求并等待读取收尾。
class BookSearchSource {
  BookSearchSource(this.books, this.contents);
  final BookRepository books;
  final ChapterContentRepository contents;
  final _epochs = <String, int>{};
  final _jobs = <String, Future<void>>{};
  final _suspended = <String>{};
  int generation(String bookId) => _epochs[bookId] ?? 0;

  /// 同书逐章读取串行执行，正文交接等待在途读取结束。
  Future<T> work<T>(String bookId, Future<T> Function() action) async {
    final epoch = generation(bookId), previous = _jobs[bookId];
    final finished = Completer<void>();
    _jobs[bookId] = finished.future;
    try {
      await previous;
      if (epoch != generation(bookId) || _suspended.contains(bookId)) {
        throw StateError('正文已经变化，请重新搜索');
      }
      return await action();
    } finally {
      finished.complete();
      if (identical(_jobs[bookId], finished.future)) _jobs.remove(bookId);
    }
  }

  Future<(Book, List<Chapter>, String)> snapshot(String bookId) async {
    final epoch = _epochs.putIfAbsent(bookId, () => 0);
    if (_suspended.contains(bookId)) {
      throw StateError('正在更新正文，请稍后重试');
    }
    final book = await books.findById(bookId);
    if (book == null || book.status != BookStatus.active) {
      throw StateError('原书不可用，请重新导入原文件');
    }
    final chapters = await books.chaptersOf(bookId);
    // 数据库读取也会让出执行权；交接可能已完成，不能拿旧快照重开文件。
    if (epoch != generation(bookId) || _suspended.contains(bookId)) {
      throw StateError('正文已经变化，请重新搜索');
    }
    final signature = sha256.convert(
      utf8.encode(
        jsonEncode([
          book.sourceHash,
          book.contentVersion,
          for (final c in chapters)
            [c.id, c.title, c.contentPath, c.textLength],
        ]),
      ),
    );
    return (
      book,
      chapters,
      signature.toString(), // 只用于核对正文身份和区分内存章缓存，不产生文件。
    );
  }

  Future<void Function()> prepareContentChange(String bookId) async {
    _suspended.add(bookId);
    _epochs[bookId] = generation(bookId) + 1;
    // 队列的完成信号始终在 finally 发出，正文读取失败也会正常结束等待。
    await _jobs[bookId];
    return () => _suspended.remove(bookId);
  }
}
