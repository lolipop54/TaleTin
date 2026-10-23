part of 'reader_session_view_model.dart';

/// 滚动位置仍由同一会话保存；显示器只回报已准备、已落位的正文。
mixin _ReaderScrollPosition on AsyncNotifier<ReaderSession> {
  ReadingLayoutMode get _mode;
  String get bookId;
  Locator? get _pendingAnchor;
  int get _jumpToken;
  set _jumpToken(int value);
  Future<void> persist();
  void cancelProgressNavigation();
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
        .chapter(
          bookId,
          chapter,
          textOnly: session.book.format == BookFormat.pdf && _mode.isOriginal,
        );
    if (!ref.mounted || request != _chapterRequest) return;
    // 扫描页只有图片，没有可表示页尾的文字偏移；原页滚动直接保留纵向比例。
    final locator = session.book.format == BookFormat.pdf && _mode.isOriginal
        ? content.pdfPage!.anchorAt(
            content,
            bookId,
            chapter.id,
            fraction,
            contentVersion: session.book.contentVersion,
          )
        : locatorForFraction(
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
    final source = await ref
        .read(epubSourceRepositoryProvider)
        .open(
          bookId: bookId,
          contentVersion: session.book.contentVersion,
          chapters: session.chapters,
        );
    try {
      final html = await source.chapterDocument(index);
      if (html == null || !ref.mounted) return null;
      final chapter = session.chapters[index];
      final map = ChapterAnchorMap.parse(
        sanitizedHtml: html,
        resourceHref: chapter.href!,
        bookId: bookId,
        contentVersion: session.book.contentVersion,
        chapterId: chapter.id,
      );
      _scrollAnchors[key] = map;
      while (_scrollAnchors.length > 3) {
        _scrollAnchors.remove(_scrollAnchors.keys.first);
      }
      return map.locatorOfAnchor(fragment);
    } finally {
      await source.close();
    }
  }

  Future<void> setScrolling(bool enabled) async {
    final session = state.value;
    if (session == null || session.scrolling == enabled) return;
    cancelProgressNavigation();
    ++_chapterRequest;
    final pending = _scrollLanding;
    _scrollLanding = null;
    if (pending != null && !pending.isCompleted) pending.complete();
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

  bool reportScrollPosition(
    ChapterContent content,
    Locator anchor, {
    int? jumpToken,
    bool atEnd = false,
  }) {
    final session = state.value;
    if (session == null || !session.scrolling) return false;
    if (jumpToken != session.scrollJump?.token) return false;
    final index = session.chapters.indexWhere((c) => c.id == anchor.chapterId);
    if (index < 0) return false;
    state = AsyncData(
      session.copyWith(
        chapterIndex: index,
        pdfAtEnd: session.book.format == BookFormat.pdf && atEnd,
        content: content,
        scrollAnchor: anchor,
        clearOriginalPosition: true,
      ),
    );
    reportDisplayArrival(anchor);
    if (jumpToken != null && jumpToken == speechScrollToken) {
      // 只有滚动显示器真实回报位置才算落位，发出跳转请求不代表已经显示。
      ref.read(readerSessionProvider(bookId).notifier)._speechDiagnostics?.step(
        'scrollArrived',
        {
          'token': jumpToken,
          'chapter': index,
          'anchor': listeningDiagnosticPosition(anchor),
          'target': listeningDiagnosticPosition(
            session.scrollJump?.locator,
            relativeTo: anchor,
          ),
        },
      );
    }
    _scrollLanding?.complete();
    _scrollLanding = null;
    return true;
  }
}
