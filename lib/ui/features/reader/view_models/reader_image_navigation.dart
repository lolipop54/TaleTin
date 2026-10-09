part of 'reader_session_view_model.dart';

extension ReaderImageNavigation on ReaderSessionNotifier {
  /// 看图窗口仍遮住正文时定位图片，等真实页码回报后才允许关闭窗口。
  Future<void> goToImage(Locator locator) async {
    await beginManualReading();
    final session = _scanSession;
    if (session.scrolling) {
      await goToLocator(locator, manual: false);
      await waitForScrollPosition();
    } else if (session.isOriginal) {
      final index = session.chapters.indexWhere((c) => c.id == locator.chapterId);
      final content = await _contentFor(session.chapters[index]);
      if (content == null) throw const ReaderFailure('图片所在章节无法读取');
      final done = Completer<void>();
      _tocLanding = (chapterId: locator.chapterId, blockId: locator.blockId,
        progress: 0, done: done);
      _clearRestoredPosition();
      _originalExact = locator;
      _pendingOriginalFraction = index == session.chapterIndex ? null : 0;
      _pendingOriginalText = null;
      _pendingOriginalAnchorId = null;
      _pendingOriginalTitle = null;
      try {
        _publishScan(session.copyWith(chapterIndex: index, content: content,
          clearOriginalPosition: index != session.chapterIndex,
          originalJump: index == session.chapterIndex
            ? (token: ++_jumpToken, fraction: 0.0, anchorId: null, title: null) : null));
        await done.future.timeout(const Duration(seconds: 10));
      } finally {
        _tocLanding = null;
      }
    } else {
      await goToLocator(locator, manual: false);
    }
    await persist();
  }
}
