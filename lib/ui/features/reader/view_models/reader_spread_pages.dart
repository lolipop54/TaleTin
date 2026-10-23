part of 'reader_session_view_model.dart';

typedef SpreadPageRef = ({ChapterLayout layout, int pageIndex});

extension ReaderSpreadPages on ReaderSessionNotifier {
  /// 只查询、准备页面。双页可能跨章，但准备右页不能改动当前阅读位置。
  Future<SpreadPageRef?> adjacentSpreadPage(
    SpreadPageRef source,
    bool forward,
  ) async {
    final snapshot = _scanSession;
    final options = source.layout.options;
    var layout = source.layout;
    final index = source.pageIndex + (forward ? 1 : -1);
    if (forward && index >= layout.pageCount && !layout.isComplete) {
      layout = await layout.ensurePage(index);
    }
    if (index >= 0 && index < layout.pageCount) {
      if (snapshot.book.format == BookFormat.pdf) {
        final chapter = snapshot.chapters.firstWhere(
          (c) => c.id == layout.chapterId,
        );
        await _sessionRef
            .read(chapterContentRepositoryProvider)
            .chapter(bookId, chapter);
      }
      return (layout: layout, pageIndex: index);
    }
    final chapterIndex =
        snapshot.chapters.indexWhere((c) => c.id == layout.chapterId) +
        (forward ? 1 : -1);
    if (chapterIndex < 0 || chapterIndex >= snapshot.chapters.length) {
      return null;
    }
    final chapter = snapshot.chapters[chapterIndex];
    final content = await _sessionRef
        .read(chapterContentRepositoryProvider)
        .chapter(bookId, chapter);
    final next = await _sessionRef
        .read(readerEngineProvider)
        .layoutWindow(
          LayoutRequest(
            bookId: bookId,
            contentVersion: snapshot.book.contentVersion,
            chapter: chapter,
            content: content,
            options: options,
          ),
          atEnd: !forward,
        );
    return next.pageCount == 0
        ? null
        : (layout: next, pageIndex: forward ? 0 : next.pageCount - 1);
  }

  Future<void> commitSpreadPage(
    SpreadPageRef origin,
    SpreadPageRef target,
  ) async {
    final session = _scanSession;
    final chapter = session.chapters.firstWhere(
      (c) => c.id == target.layout.chapterId,
    );
    final content = await _sessionRef
        .read(chapterContentRepositoryProvider)
        .chapter(bookId, chapter);
    await commitScanPage(
      current: origin.layout,
      currentPage: origin.pageIndex,
      next: target.layout,
      nextPage: target.pageIndex,
      content: content,
    );
  }
}
