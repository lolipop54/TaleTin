part of '../repositories/file_chapter_content_repository.dart';

/// 原生句柄只在原有PDFium队列使用；文件和JSON由正文worker持有。
extension _PdfChapterReading on FileChapterContentRepository {
  Future<PdfFile> _pdfFile(String bookId) async {
    final file =
        _pdfReaders.remove(bookId) ??
        PdfFile.open(bookSourcePath(p.join(libraryRoot, bookId), 'pdf'));
    _pdfReaders[bookId] = file;
    while (_pdfReaders.length > 2) {
      final idle = _pdfReaders.keys
          .where(
            (id) =>
                id != bookId &&
                !_pendingChapters.keys.any((key) => key.startsWith('$id/')),
          )
          .firstOrNull;
      if (idle == null) break;
      await _closePdfReaders(idle);
    }
    return file;
  }

  Future<ChapterContent> _pdfChapter(String bookId, Chapter chapter) async {
    final worker = await _contentWorker();
    final key = '$bookId/${chapter.id}';
    var content =
        await worker.pdf('start', (key, bookId, chapter)) as ChapterContent;
    try {
      if (content.pdfPage!.pendingPictures) {
        content = await preparePdfPagePictures(await _pdfFile(bookId), content);
      }
      final missing = await worker.pdf('missing', (
        key,
        content,
      )) as List<(String, int, List<double>)>;
      for (final (path, width, box) in missing) {
        final pdf = await _pdfFile(bookId);
        final bytes = await pdf.render(content.pdfPage!.index, width, box: box);
        await worker.pdf('image', (key, path, bytes));
      }
      // 文件、图片及保护记录一起就绪才交付，不能提前显示缺图的正文。
      await worker.pdf('finish', (key, content));
      _chapters[key] = content;
      while (_chapters.length > cacheCapacity) {
        _chapters.remove(_chapters.keys.first);
      }
      return content;
    } finally {
      await worker.pdf('abort', key);
    }
  }

  Future<void> _closePdfReaders(String? bookId) async {
    for (final key in _pdfReaders.keys.toList()) {
      if (bookId == null || key == bookId) {
        final closing = _pdfReaders.remove(key)!.then((pdf) => pdf.close());
        _pdfClosings.add(closing);
        try {
          await closing;
        } finally {
          _pdfClosings.remove(closing);
        }
      }
    }
  }
}
