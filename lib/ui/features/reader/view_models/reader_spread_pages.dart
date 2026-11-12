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
    final layout = source.layout;
    final adjacent = await layout.adjacentPage(
      source.pageIndex,
      forward: forward,
    );
    if (adjacent != null) {
      if (snapshot.book.format == BookFormat.pdf) {
        final chapter = snapshot.chapters.firstWhere(
          (c) => c.id == layout.chapterId,
        );
        await _sessionRef
            .read(chapterContentRepositoryProvider)
            .chapter(bookId, chapter);
      }
      return adjacent;
    }
    final chapterIndex =
        snapshot.chapters.indexWhere((c) => c.id == layout.chapterId) +
        (forward ? 1 : -1);
    if (chapterIndex < 0 || chapterIndex >= snapshot.chapters.length) {
      return null;
    }
    final next = await _prepareNeighborChapter(
      snapshot,
      chapterIndex,
      options,
      atEnd: !forward,
    );
    return next.pageCount == 0
        ? null
        : (layout: next, pageIndex: forward ? 0 : next.pageCount - 1);
  }

  /// 从当前左页按实际页数前后数，沿用连续翻页时的左右配对。
  Future<SpreadPageRef> _spreadLeftForImage(
    ReaderSession session,
    SpreadPageRef origin,
    Locator locator,
  ) async {
    final from = session.chapterIndex;
    final to = session.chapters.indexWhere((c) => c.id == locator.chapterId);
    if (to < 0) throw const ReaderFailure('图片所在章节无法读取');
    final options = origin.layout.options;
    var distance = -origin.pageIndex;
    ChapterLayout? target = from == to ? origin.layout : null;
    final direction = to >= from ? 1 : -1;
    for (var chapter = from; chapter != to; chapter += direction) {
      // 只数当前章到目标章之间的页。往前数时扣掉前一章的真实页数。
      final index = direction > 0 ? chapter : chapter - 1;
      final end = await _prepareNeighborChapter(
        session,
        index,
        options,
        atEnd: true,
      );
      distance += direction * end.pageCount;
      if (index == to) target = end;
    }
    target ??= await _prepareNeighborChapter(session, to, options);
    final layout = await target.ensureTarget(locator);
    final index = layout.pageIndexOf(locator);
    if (index == null) throw const ReaderFailure('无法定位图片所在页');
    final page = (layout: layout, pageIndex: index);
    // 相差奇数页时目标在右侧，左页有可能在上一章。
    return (distance + index).isOdd
        ? await adjacentSpreadPage(page, false) ?? page
        : page;
  }

  Future<void> commitSpreadPage(
    SpreadPageRef origin,
    SpreadPageRef target,
  ) async {
    final session = _scanSession;
    final chapter = session.chapters.firstWhere(
      (c) => c.id == target.layout.chapterId,
    );
    final content = session.book.format == BookFormat.txt
        ? target.layout.content
        : await _sessionRef
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
