part of 'reader_session_view_model.dart';

extension ReaderScanCommit on ReaderSessionNotifier {
  /// 重复句的页首由真实 DOM 点确定，不能搜索相同摘录后落到第一次出现的位置。
  Future<void> commitOriginalScanPosition(
    Locator locator,
    double fraction,
  ) async {
    _originalReportExact = locator;
    _exactOriginalFraction = fraction;
    _publishScan(
      _scanSession.copyWith(
        originalAnchor: locator,
        originalFraction: fraction,
      ),
    );
    await persist();
  }

  /// 只提交已经准备好的相邻页，不重新排版，也不走会暂停自动任务的手动入口。
  Future<void> commitScanPage({
    required ChapterLayout current,
    required int currentPage,
    required ChapterLayout next,
    required int nextPage,
    required ChapterContent content,
  }) async {
    final session = _scanSession;
    if (!current.samePageAs(session.layout, currentPage) ||
        session.pageIndex != currentPage) {
      throw StateError('扫描期间阅读位置已改变');
    }
    final chapter = session.chapters.indexWhere((c) => c.id == next.chapterId);
    _clearRestoredPosition();
    if (chapter != session.chapterIndex) {
      ++_tokenVersion;
      _token?.cancel();
      _previousChapterLayout = current;
      _nextChapterLayout = null;
    }
    _publishScan(
      session.copyWith(
        chapterIndex: chapter,
        content: content,
        layout: next,
        pageIndex: nextPage,
      ),
    );
    await persist();
    if (chapter != session.chapterIndex && _options != null) {
      _prefetchNext(chapter, _options!);
    }
  }
}
