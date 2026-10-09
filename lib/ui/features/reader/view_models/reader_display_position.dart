part of 'reader_session_view_model.dart';

/// 四种正文显示共用位置；没有继续阅读时，切回来沿用各自的原落点。
mixin _ReaderDisplayPosition
    on AsyncNotifier<ReaderSession>, _ReaderOriginalPosition, _ReaderScrollPosition {
  set _pendingAnchor(Locator? value);
  LayoutToken? get _token;
  final _displayPositions = <(ReadingLayoutMode, bool), Locator>{};
  final _displayArrivals = <(ReadingLayoutMode, bool), Locator>{};
  bool _displayWaiting = false;
  int _displayVersion = 0;
  Locator? _displayTarget;
  (ReadingLayoutMode, bool)? _displayDesired;
  Locator? get displayTarget => _displayTarget;

  @override
  void reportDisplayArrival(Locator anchor) {
    if (!_displayWaiting) return;
    _displayWaiting = false;
    _displayTarget = null;
    _displayArrivals[(_mode, state.value?.scrolling ?? false)] = anchor;
  }

  Future<void> switchReadingDisplay(ReadingLayoutMode mode, bool scrolling) async {
    final session = state.value;
    if (session == null) return;
    if (session.book.format != BookFormat.epub) mode = ReadingLayoutMode.simplified;
    final desired = (mode, scrolling);
    if ((_displayDesired ?? (_mode, session.scrolling)) == desired) return;
    _displayDesired = desired;
    final previous = (_mode, session.scrolling);
    final anchor = session.currentAnchor ?? _pendingAnchor;
    if (anchor == null) {
      setLayoutMode(mode);
      await setScrolling(scrolling);
      return;
    }
    final arrival = _displayArrivals[previous];
    if (arrival == null || !arrival.samePosition(anchor)) _displayPositions.clear();
    _displayPositions[previous] = anchor;
    final target = _displayPositions[(mode, scrolling)] ?? anchor;
    final version = ++_displayVersion;
    _token?.cancel();
    ref.read(readerProvider.notifier).clearSelection();
    _mode = mode;
    _displayWaiting = true;
    _displayTarget = target;
    _pendingAnchor = target;
    if (scrolling) {
      state = AsyncData(session.copyWith(scrolling: true, scrollAnchor: anchor,
        clearOriginalPosition: true,
        scrollJump: (token: ++_jumpToken, locator: target)));
      return;
    }
    final index = session.chapters.indexWhere((c) => c.id == target.chapterId);
    final content = await ref.read(chapterContentRepositoryProvider)
        .chapter(bookId, session.chapters[index]);
    if (!ref.mounted || version != _displayVersion) return;
    // 新显示准备期间仍保留确认过的位置；分页结果不能沿用另一章的旧排版。
    state = AsyncData(ReaderSession(book: session.book, chapters: session.chapters,
      chapterIndex: index, content: content, originalAnchor: anchor,
      originalFraction: session.chapterProgress));
    if (mode.isOriginal) {
      _originalExact = target;
      _pendingOriginalFraction = null;
      _pendingOriginalText = null;
    } else if (_options != null) {
      await goToLocator(target, manual: false);
    }
  }
}
