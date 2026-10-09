part of 'reader_session_view_model.dart';

/// 滚动位置仍由同一会话保存；显示器只回报已准备、已落位的正文。
mixin _ReaderScrollPosition on AsyncNotifier<ReaderSession> {
  String get bookId;
  Locator? get _pendingAnchor;
  int get _jumpToken;
  set _jumpToken(int value);
  Future<void> persist();
  void reportDisplayArrival(Locator anchor);
  Future<void> goToLocator(
    Locator locator, {
    bool restoringListening = false,
    bool manual = true,
  });

  Locator? get scrollOpeningAnchor =>
      state.value?.currentAnchor ?? _pendingAnchor;

  Completer<void>? _scrollLanding;
  int _chapterRequest = 0;
  final _scrollAnchors = <(int, int), ChapterAnchorMap>{};
  Future<void>? get pendingScrollPosition => _scrollLanding?.future;
  Future<void> waitForScrollPosition() async {
    await pendingScrollPosition?.timeout(const Duration(seconds: 10));
  }

  int? speechScrollToken;

  void requestScrollPosition(Locator locator, {bool animated = false}) {
    final session = state.value;
    if (session == null) return;
    ++_chapterRequest;
    if (_scrollLanding case final previous? when !previous.isCompleted) {
      previous.complete();
    }
    _scrollLanding = Completer<void>();
    speechScrollToken = animated ? _jumpToken + 1 : null;
    state = AsyncData(
      session.copyWith(scrollJump: (token: ++_jumpToken, locator: locator)),
    );
  }

  Future<void> requestScrollChapter(int index, {double fraction = 0}) async {
    final request = ++_chapterRequest;
    final session = state.value;
    if (session == null) return;
    final chapter = session.chapters[index];
    final content = await ref
        .read(chapterContentRepositoryProvider)
        .chapter(bookId, chapter);
    if (!ref.mounted || request != _chapterRequest) return;
    final locator = locatorForFraction(
      content: content,
      bookId: bookId,
      contentVersion: session.book.contentVersion,
      chapterId: chapter.id,
      fraction: fraction,
    );
    if (locator != null) requestScrollPosition(locator);
  }

  /// XHTML 内的目录锚点与书内链接共用净化正文对照，不按重复标题猜位置。
  Future<Locator?> scrollLinkAnchor(int index, String fragment) async {
    final session = state.value!;
    final key = (session.book.contentVersion, index);
    final held = _scrollAnchors.remove(key);
    if (held != null) {
      _scrollAnchors[key] = held;
      return held.locatorOfAnchor(fragment);
    }
    final source = ref.read(epubSourceRepositoryProvider).open(bookId: bookId,
      contentVersion: session.book.contentVersion, chapters: session.chapters);
    try {
      final html = await source.chapterDocument(index);
      if (html == null || !ref.mounted) return null;
      final chapter = session.chapters[index];
      final map = ChapterAnchorMap.parse(sanitizedHtml: html, resourceHref: chapter.href!,
        bookId: bookId, contentVersion: session.book.contentVersion, chapterId: chapter.id);
      _scrollAnchors[key] = map;
      while (_scrollAnchors.length > 3) { _scrollAnchors.remove(_scrollAnchors.keys.first); }
      return map.locatorOfAnchor(fragment);
    } finally { source.close(); }
  }

  Future<void> setScrolling(bool enabled) async {
    final session = state.value;
    if (session == null || session.scrolling == enabled) return;
    final anchor = scrollOpeningAnchor;
    state = AsyncData(
      session.copyWith(
        scrolling: enabled,
        scrollAnchor: anchor,
        clearOriginalPosition: true,
      ),
    );
    if (!enabled && anchor != null) await goToLocator(anchor, manual: false);
  }

  bool reportScrollPosition(ChapterContent content, Locator anchor, {int? jumpToken}) {
    final session = state.value;
    if (session == null || !session.scrolling) return false;
    if (jumpToken != session.scrollJump?.token) return false;
    final index = session.chapters.indexWhere((c) => c.id == anchor.chapterId);
    if (index < 0) return false;
    state = AsyncData(
      session.copyWith(
        chapterIndex: index,
        content: content,
        scrollAnchor: anchor,
        clearOriginalPosition: true,
      ),
    );
    reportDisplayArrival(anchor);
    _scrollLanding?.complete();
    _scrollLanding = null;
    return true;
  }
}
