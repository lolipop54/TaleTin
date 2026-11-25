part of 'reader_session_view_model.dart';

extension ReaderImageNavigation on ReaderSessionNotifier {
  /// 关闭看图窗口前，只在需要换页时重新定位正文。
  Future<void> goToImage(
    Locator locator, {
    void Function(String step, [SpreadPageRef? spreadLeft])? onStep,
  }) async {
    final current = _scanSession;
    if (!current.isOriginal &&
        !current.scrolling &&
        current.layout?.options.settings.spreadEnabled == true) {
      final pages = _sessionRef.read(visibleSpreadProvider(bookId));
      // 当前两页中已有这张图就保留原来的阅读位置。换页期间，
      // 屏幕上还保留的旧画面不能算作新落点。
      if (spreadShowsSession(pages, current) &&
          spreadContains(pages, locator)) {
        return;
      }
    }
    onStep?.call('beginManualReading');
    await beginManualReading();
    final session = _scanSession;
    if (session.scrolling) {
      onStep?.call('requestScrollPosition');
      await goToLocator(locator, manual: false);
      onStep?.call('waitForScrollPosition');
      await waitForScrollPosition();
    } else if (session.isOriginal) {
      onStep?.call('returnToOriginalPage');
      final index = session.chapters.indexWhere(
        (c) => c.id == locator.chapterId,
      );
      final content = await _contentFor(session.chapters[index]);
      if (content == null) throw const ReaderFailure('图片所在章节无法读取');
      final done = Completer<void>();
      _tocLanding = (
        chapterId: locator.chapterId,
        blockId: locator.blockId,
        progress: 0,
        done: done,
      );
      _clearRestoredPosition();
      _originalExact = locator;
      _pendingOriginalFraction = index == session.chapterIndex ? null : 0;
      _pendingOriginalText = null;
      _pendingOriginalAnchorId = null;
      _pendingOriginalTitle = null;
      try {
        _publishScan(
          session.copyWith(
            chapterIndex: index,
            content: content,
            clearOriginalPosition: index != session.chapterIndex,
            originalJump: index == session.chapterIndex
                ? (
                    token: ++_jumpToken,
                    fraction: 0.0,
                    anchorId: null,
                    title: null,
                  )
                : null,
          ),
        );
        await done.future.timeout(const Duration(seconds: 10));
      } finally {
        _tocLanding = null;
      }
    } else if (session.layout case final layout?
        when layout.options.settings.spreadEnabled) {
      await _goToImageSpread(locator, onStep);
    } else {
      onStep?.call('returnToSinglePage');
      await goToLocator(locator, manual: false);
    }
    onStep?.call('persistPosition');
    await persist();
  }

  Future<void> _goToImageSpread(
    Locator locator,
    void Function(String step, [SpreadPageRef? spreadLeft])? onStep,
  ) async {
    onStep?.call('findSpread');
    await goToLocator(locator, manual: false);
    if (!_sessionRef.mounted || _visualPresenters.isEmpty) return;
    final shown = Completer<void>();
    // 等双页和图片都上屏后再撤掉看图窗口，避免关掉时先露出旧页。
    final subscription = _sessionRef.listen(visibleSpreadProvider(bookId), (
      _,
      pages,
    ) {
      if (!shown.isCompleted &&
          pages.isNotEmpty &&
          spreadContains(pages, locator)) {
        shown.complete();
      }
    }, fireImmediately: true);
    try {
      onStep?.call('waitForVisibleSpread');
      await shown.future.timeout(const Duration(seconds: 10));
    } finally {
      subscription.close();
    }
  }
}
