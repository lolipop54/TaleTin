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
    final key = (layout.identity, page);
    if (_confirmedPage == key) return;
    _confirmedPage = key;
    _confirmedVisualPosition = _visualPosition(latest);
    unawaited(persist());
  }
}
