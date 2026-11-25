part of 'reader_session_view_model.dart';

typedef SpreadPageRef = ({ChapterLayout layout, int pageIndex});

extension ReaderSpreadPages on ReaderSessionNotifier {
  /// 卷页已经画出的那一页就是落页。快速回翻时邻章预取可能仍在更换，
  /// 不能在松手或动画结束时再从邻章缓存里另取一份页面。
  Future<bool> commitManualPage(
    SpreadPageRef origin,
    SpreadPageRef target,
  ) async {
    cancelProgressNavigation();
    await beginManualReading();
    if (!_sessionRef.mounted) return false;
    final session = _scanSession;
    if (!origin.layout.samePageAs(
      session.layout,
      origin.pageIndex,
      session.pageIndex,
    )) {
      return false;
    }
    _clearRestoredPosition();
    if (origin.layout.chapterId == target.layout.chapterId) {
      _publishScan(
        session.copyWith(layout: target.layout, pageIndex: target.pageIndex),
      );
      unawaited(persist());
      return true;
    }
    final index = session.chapters.indexWhere(
      (chapter) => chapter.id == target.layout.chapterId,
    );
    return _layoutChapter(
      chapterIndex: index,
      options: target.layout.options,
      anchor: null,
      atChapterEnd: index < session.chapterIndex,
      preparedLayout: target.layout,
    );
  }

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
    final origin = snapshot.chapters.indexWhere(
      (c) => c.id == layout.chapterId,
    );
    if (origin < 0) return null;
    return _readableNeighbor(snapshot, origin, options, forward);
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

extension _ReadableNeighbor on _ReaderLayoutCoordinator {
  // 超长 TXT 的转换与用户跳转共用正文后台任务。留给真正的翻页或跳转请求，
  // 防止刚到目标页就排队解码两侧长章，拖慢随后返回或再次跳转。
  bool _canPrefetchChapter(ReaderSession session, int index) =>
      session.book.format != BookFormat.txt ||
      session.chapters[index].textLength < kLongTxtChapterLength;

  /// 沿书内顺序寻找真正排出页面的章节。纯图片章有页，空锚点章没有页。
  Future<SpreadPageRef?> _readableNeighbor(
    ReaderSession session,
    int origin,
    LayoutOptions options,
    bool forward,
  ) async {
    final step = forward ? 1 : -1;
    final version = _tokenVersion;
    for (
      var index = origin + step;
      index >= 0 && index < session.chapters.length;
      index += step
    ) {
      ChapterLayout? layout;
      if (session.book.format != BookFormat.pdf) {
        for (final cached in [
          session.layout,
          _nextChapterLayout,
          _previousChapterLayout,
        ]) {
          final ready = _matchingChapterLayout(cached, session, index, options);
          if (ready != null &&
              !ready.paginatesTxtInWindows &&
              (ready.isComplete && ready.pageCount == 0 ||
                  (forward || ready.isComplete) &&
                      ready.page(forward ? 0 : ready.pageCount - 1) != null)) {
            layout = ready;
            break;
          }
        }
      }
      layout ??= await _prepareNeighborChapter(
        session,
        index,
        options,
        atEnd: !forward,
      );
      if (_tokenVersion != version) {
        throw const LayoutCancelled(LayoutCancellationReason.requestSuperseded);
      }
      if (layout.pageCount > 0) {
        return (
          layout: layout,
          pageIndex: forward ? layout.firstPage : layout.pageCount - 1,
        );
      }
    }
    return null;
  }
}
