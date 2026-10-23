import 'dart:async';
import 'dart:typed_data';

import '../../domain/models/book.dart';
import '../../domain/models/book_document.dart';
import '../../domain/repositories/chapter_content_repository.dart';
import '../../engine/parsers/pdf/pdf_file.dart';
import 'book_source_path.dart';

/// 单书PDF句柄。先由正文仓库核验来源，再渲染；关闭等待在途任务释放原生资源。
class PdfBookController {
  PdfBookController._(this.book, this.chapters, this.contents, this.file);
  final Book book;
  final List<Chapter> chapters;
  final ChapterContentRepository contents;
  final PdfFile file;
  final _pending = <Future<void>>{};
  bool _closed = false;
  Future<void>? _closing;

  static Future<PdfBookController> open(
    Book book,
    List<Chapter> chapters,
    ChapterContentRepository contents,
    String directory,
  ) async => PdfBookController._(
    book,
    chapters,
    contents,
    await PdfFile.open(bookSourcePath(directory, 'pdf')),
  );

  Future<ChapterContent> content(int index) =>
      contents.chapter(book.id, chapters[index], textOnly: true);

  Future<Uint8List> render(int index, int width) async {
    return _render(index, () => file.render(index, width));
  }

  Future<(int, int, Uint8List)> raster(int index, int width) =>
      _render(index, () => file.raster(index, width));

  Future<T> _render<T>(int index, Future<T> Function() action) async {
    if (_closed) throw StateError('PDF阅读会话已关闭');
    final task = () async {
      await content(index); // 缓存/句柄不能绕过源文件内容核验。
      return action();
    }();
    final done = task.then<void>((_) {}, onError: (Object _) {});
    _pending.add(done);
    try {
      return await task;
    } finally {
      _pending.remove(done);
    }
  }

  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _closed = true;
    await Future.wait(_pending.toList());
    await file.close();
  }
}
