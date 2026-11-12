part of 'reader_session_view_model.dart';

/// 四种正文显示共用位置；没有继续阅读时，切回来沿用各自的原落点。
mixin _ReaderDisplayPosition
    on
        AsyncNotifier<ReaderSession>,
        _ReaderOriginalPosition,
        _ReaderScrollPosition {
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

  Future<void> switchReadingDisplay(
    ReadingLayoutMode mode,
    bool scrolling,
  ) async {
    final session = state.value;
    if (session == null) return;
    mode = mode.forBuild(pdf: session.book.format == BookFormat.pdf);
    if (!session.book.format.supportsOriginalLayout) {
      mode = ReadingLayoutMode.simplified;
    }
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
    if (arrival == null || !arrival.samePosition(anchor)) {
      _displayPositions.clear();
    }
    _displayPositions[previous] = anchor;
    // TXT 两种显示用同一个正文坐标。交接时以正在看的段落为准，
    // 已使用过的滚动窗口不能把后来翻到的小节拉回旧位置。
    final target = session.book.format == BookFormat.txt
        ? anchor
        : _displayPositions[desired] ?? anchor;
    final version = ++_displayVersion;
    _token?.cancel();
    ref.read(readerProvider.notifier).clearSelection();
    _mode = mode;
    _displayWaiting = true;
    _displayTarget = target;
    _pendingAnchor = target;
    if (scrolling) {
      state = AsyncData(
        session.copyWith(
          scrolling: true,
          scrollAnchor: anchor,
          clearOriginalPosition: true,
          scrollJump: (token: ++_jumpToken, locator: target),
        ),
      );
      return;
    }
    final index = session.chapters.indexWhere((c) => c.id == target.chapterId);
    final chapter = session.chapters[index];
    final repository = ref.read(chapterContentRepositoryProvider);
    // 长 TXT 的目标段落足以开始分页，不必在滚动交接时读取整章。
    final bySection =
        session.book.format == BookFormat.txt &&
        chapter.textLength >= kLongTxtChapterLength &&
        await repository.txtChapterSource(bookId, chapter) != null;
    if (!ref.mounted || version != _displayVersion) return;
    final content = bySection
        ? null
        : await repository.chapter(
            bookId,
            chapter,
            textOnly: session.book.format == BookFormat.pdf && mode.isOriginal,
          );
    if (!ref.mounted || version != _displayVersion) return;
    // 新显示准备期间仍保留确认过的位置；分页结果不能沿用另一章的旧排版。
    state = AsyncData(
      ReaderSession(
        book: session.book,
        chapters: session.chapters,
        chapterIndex: index,
        content: content,
        originalAnchor: anchor,
        originalFraction: session.chapterProgress,
      ),
    );
    if (mode.isOriginal) {
      _originalExact = target;
      _pendingOriginalFraction = null;
      _pendingOriginalText = null;
    } else if (_options != null) {
      await goToLocator(target, manual: false);
    }
  }
}
