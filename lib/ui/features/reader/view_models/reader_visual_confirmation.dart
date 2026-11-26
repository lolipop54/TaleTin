part of 'reader_session_view_model.dart';

/// 准备分页、补索引都不算“已经读到”；由实际画面确认唯一可保存的位置。
extension _ReaderVisualConfirmation on ReaderSessionNotifier {
  ReadingPosition? _visualPosition(ReaderSession session) {
    final anchor = session.currentAnchor;
    if (anchor == null) return null;
    final contentBased =
        ReaderDeliveryExperiments.contentTarget &&
        (!session.isOriginal || session.originalContentProgress);
    return _restoredPosition(anchor) ??
        ReadingPosition(
          locator: anchor,
          progress: contentBased
              ? session.contentProgress
              : session.bookProgress,
          progressBasis: contentBased
              ? ReadingProgressBasis.content
              : ReadingProgressBasis.legacyVisual,
        );
  }

  void _confirmSimplifiedPage(ChapterLayout layout, int page) {
    final latest = _progressSession;
    if (!_sessionRef.mounted ||
        _mode.isOriginal ||
        latest == null ||
        latest.scrolling ||
        !layout.samePageAs(latest.layout, page, latest.pageIndex)) {
      return;
    }
    // 现在静态正文已经接手。此时才开始读下一章的图片和正文；
    // 快速回翻时即使回到上次确认过的页，也要接走本轮预取。
    final prepare = _prefetchAfterPageShown;
    _prefetchAfterPageShown = null;
    prepare?.call();
    final key = (layout.identity, page);
    final anchor = latest.currentAnchor;
    if (_confirmedPage == key &&
        (latest.spreadTarget == null ||
            (anchor != null &&
                _confirmedVisualPosition?.locator.samePosition(anchor) ==
                    true))) {
      return;
    }
    // 回翻到本章第一页时也要准备上一章末页。只在落页后启动，拖动取消不抢时间。
    if (page == 0 && _confirmedPage?.$1 == layout.identity && prepare == null) {
      _prefetchPrevious(latest.chapterIndex, layout.options);
    }
    final trace = ReaderWorkTrace.start('reader.confirm_page');
    _confirmedPage = key;
    _confirmedVisualPosition = _visualPosition(latest);
    if (layout.readsBySection && latest.book.format.usesOriginalWebView) {
      _sessionRef
          .read(chapterContentRepositoryProvider)
          .queuePublicationDraftSave(
            bookId,
            latest.chapters[latest.chapterIndex],
          );
    }
    trace?.mark('position');
    unawaited(persist());
    trace?.finish();
  }
}
