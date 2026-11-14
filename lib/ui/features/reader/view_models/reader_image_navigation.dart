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
      // 直接跳到已在右侧的图片会把它当成新的左页。只用与当前会话
      // 对得上的画面来判断，避免把换页期间还显示的旧页当成当前页。
      if (pages.isNotEmpty &&
          pages.first.layout.samePageAs(
            current.layout,
            pages.first.pageIndex,
            current.pageIndex,
          ) &&
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
      await _goToImageSpread(session, layout, locator, onStep);
    } else {
      onStep?.call('returnToSinglePage');
      await goToLocator(locator, manual: false);
    }
    onStep?.call('persistPosition');
    await persist();
  }

  Future<void> _goToImageSpread(
    ReaderSession session,
    ChapterLayout layout,
    Locator locator,
    void Function(String step, [SpreadPageRef? spreadLeft])? onStep,
  ) async {
    cancelProgressNavigation();
    final origin = (layout: layout, pageIndex: session.pageIndex);
    onStep?.call('findSpread');
    final left = await _spreadLeftForImage(session, origin, locator);
    if (!_sessionRef.mounted) return;
    onStep?.call('commitSpread', left);
    if (_visualPresenters.isEmpty) {
      await commitSpreadPage(origin, left);
      return;
    }
    final shown = Completer<void>();
    // 等双页和图片都上屏后再撤掉看图窗口，避免关掉时先露出旧页。
    final subscription = _sessionRef.listen(visibleSpreadProvider(bookId), (
      _,
      pages,
    ) {
      if (!shown.isCompleted &&
          pages.isNotEmpty &&
          left.layout.samePageAs(
            pages.first.layout,
            left.pageIndex,
            pages.first.pageIndex,
          ) &&
          spreadContains(pages, locator)) {
        shown.complete();
      }
    }, fireImmediately: true);
    try {
      await commitSpreadPage(origin, left);
      onStep?.call('waitForVisibleSpread');
      await shown.future.timeout(const Duration(seconds: 10));
    } finally {
      subscription.close();
    }
  }
}
