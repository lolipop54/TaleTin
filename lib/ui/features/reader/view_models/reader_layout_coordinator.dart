part of 'reader_session_view_model.dart';

/// 集中章节排版、相邻章预取和过期结果丢弃，状态仍由主 Notifier 提交。
mixin _ReaderLayoutCoordinator on AsyncNotifier<ReaderSession> {
  String get bookId;
  LayoutOptions? get _options;
  set _options(LayoutOptions? value);
  ReadingPosition? get _listeningRestore;
  Map<ReadingLayoutMode, Locator> get _restoreArrivals;
  ReadingLayoutMode get _mode;
  ChapterLayout? get _nextChapterLayout;
  set _nextChapterLayout(ChapterLayout? value);
  ChapterLayout? get _previousChapterLayout;
  set _previousChapterLayout(ChapterLayout? value);
  LayoutToken? get _token;
  set _token(LayoutToken? value);
  int get _tokenVersion;
  set _tokenVersion(int value);
  Locator? get _pendingAnchor;
  set _pendingAnchor(Locator? value);

  ReadingPosition? _restoredPosition(Locator anchor);
  Future<void> persist();
  Locator? get displayTarget;
  void reportDisplayArrival(Locator anchor);

  /// 对齐排版参数与正文区尺寸（界面在 LayoutBuilder 里拿到尺寸后调用）。
  ///
  /// 参数没变就什么都不做；变了则重排并停在原页首位置（设计文档 6.4）。
  ///
  /// [prefetch] 为 false 时不预取相邻章：原书模式下正文由 WebView 画，
  /// 预取相邻章只在切回简化模式、翻到章末时才用得上，没必要每次都排两章。
  ///
  /// [paginate] 为 false 时只记下排版参数、不排：原书模式的正文由 WebView 画，
  /// 这份简化排版只有切回简化模式才用得上，而排一整章要按字数花时间——
  /// 《天下刀宗》整本正文是一个章节（26 万字），实测打开时白排了 2.2 秒
  /// （WebView 自己分栏 1.5 秒）。切回简化模式时按需再排（见 [setLayoutMode]）。
  Future<void> applyViewport(
    LayoutOptions options, {
    bool prefetch = true,
    bool paginate = true,
  }) async {
    final session = state.value;
    if (session == null) return;
    final unchanged =
        session.isReady &&
        session.viewportSignature == options.layoutSignature &&
        _options?.layoutSignature == options.layoutSignature;
    _options = options;
    if (unchanged || !paginate) return;
    final restored = session.currentAnchor == null
        ? _listeningRestore
        : _restoredPosition(session.currentAnchor!);
    if (restored != null) _restoreArrivals.remove(_mode);
    await _layoutChapter(
      chapterIndex: session.chapterIndex,
      options: options,
      // 首次排版时用上次退出时的位置落页（设计文档 7.1）
      anchor: displayTarget ?? restored?.locator ?? session.currentAnchor ?? _pendingAnchor,
      prefetch: prefetch,
    );
  }

  /// 翻页过渡需要的下一页：章内下一页，或已预取的下一章首页。
  ({ChapterLayout layout, int pageIndex})? peekNext() {
    final session = state.value;
    if (session == null || !session.isReady) return null;
    if (session.pageIndex + 1 < session.pageCount) {
      return (layout: session.layout!, pageIndex: session.pageIndex + 1);
    }
    final next = _nextChapterLayout;
    if (next != null && next.pageCount > 0) {
      return (layout: next, pageIndex: 0);
    }
    return null;
  }

  /// 翻页过渡需要的上一页：章内上一页，或已预取的上一章最后一页。
  ///
  /// 章首（pageIndex == 0）往回拖也要能看到上一页：跨章往回翻时上一章刚排过，
  /// 预取基本直接命中排版缓存，这里就能立刻给出它的最后一页。
  ({ChapterLayout layout, int pageIndex})? peekPrevious() {
    final session = state.value;
    if (session == null || !session.isReady) return null;
    if (session.pageIndex > 0) {
      return (layout: session.layout!, pageIndex: session.pageIndex - 1);
    }
    final previous = _previousChapterLayout;
    if (previous != null && previous.pageCount > 0) {
      return (layout: previous, pageIndex: previous.pageCount - 1);
    }
    return null;
  }

  /// 动画开始前补齐尚未预取的相邻页，不提前修改阅读位置。
  Future<({ChapterLayout layout, int pageIndex})?> prepareAdjacent(
    bool forward,
  ) async {
    final cached = forward ? peekNext() : peekPrevious();
    if (cached != null) return cached;
    final session = state.value, options = _options;
    if (session == null || options == null) return null;
    final index = session.chapterIndex + (forward ? 1 : -1);
    if (index < 0 || index >= session.chapters.length) return null;
    final chapter = session.chapters[index];
    final content = await ref
        .read(chapterContentRepositoryProvider)
        .chapter(bookId, chapter);
    final layout = await ref
        .read(readerEngineProvider)
        .layoutChapter(
          LayoutRequest(
            bookId: bookId,
            contentVersion: session.book.contentVersion,
            chapter: chapter,
            content: content,
            options: options,
          ),
        );
    return (layout: layout, pageIndex: forward ? 0 : layout.pageCount - 1);
  }

  /// 全书字数（进度分母；书表没写时用章节之和兜底）
  int bookTotalChars(ReaderSession session) {
    if (session.book.textLength > 0) return session.book.textLength;
    var total = 0;
    for (final chapter in session.chapters) {
      total += chapter.textLength;
    }
    return total;
  }

  Future<bool> _layoutChapter({
    required int chapterIndex,
    required LayoutOptions? options,
    required Locator? anchor,
    bool atChapterEnd = false,
    int? chapterOffset,
    bool prefetch = true,
  }) async {
    final session = state.value;
    if (session == null || options == null) return false;
    final chapter = session.chapters[chapterIndex];
    final contents = ref.read(chapterContentRepositoryProvider);
    final engine = ref.read(readerEngineProvider);

    // 旧排版作废：切章或改参数后回来的结果不再上屏
    final token = LayoutToken(++_tokenVersion);
    _token?.cancel();
    _token = token;

    // 相邻章的预取结果一并作废：换了章或改了参数，旧的相邻页会画错内容。
    // 先清掉，等这次排版完成后的新预取填回来。
    _nextChapterLayout = null;
    _previousChapterLayout = null;

    final ChapterContent content;
    try {
      content = chapterIndex == session.chapterIndex && session.content != null
          ? session.content!
          : await contents.chapter(bookId, chapter);
    } on Object catch (error) {
      if (!token.isCancelled) {
        state = AsyncError(error, StackTrace.current);
      }
      return false;
    }
    if (token.isCancelled) return false;

    final ChapterLayout layout;
    try {
      layout = await traceTurnStep('load simplified-layout', () => engine.layoutChapter(
        LayoutRequest(
          bookId: bookId,
          contentVersion: session.book.contentVersion,
          chapter: chapter,
          content: content,
          options: options,
        ),
        token: token,
      ));
    } on LayoutCancelled {
      return false;
    }
    if (token.isCancelled) return false;

    final pageIndex = switch ((anchor, chapterOffset, atChapterEnd)) {
      (final Locator target, _, _) => layout.pageIndexOf(target) ?? 0,
      (_, final int offset, _) => _pageForChapterOffset(layout, offset),
      // 空章节（没有正文，比如封面页）没有页，落回第 0 页而不是 -1
      (_, _, true) => layout.pageCount == 0 ? 0 : layout.pageCount - 1,
      _ => 0,
    };

    // 上次的位置用完了（第一次排版就落在它那一页）
    _pendingAnchor = null;

    // 原书模式下位置由 WebView 上报，重排（改字号、改窗口尺寸）不该把它丢掉：
    // 只有还在同一章时才带过去——换到别的章，旧位置就作废了
    final keepOriginal =
        _mode.isOriginal && chapterIndex == session.chapterIndex;

    state = AsyncData(
      ReaderSession(
        book: session.book,
        chapters: session.chapters,
        chapterIndex: chapterIndex,
        content: content,
        layout: layout,
        pageIndex: pageIndex.clamp(0, layout.pageCount - 1),
        viewportSignature: options.layoutSignature,
        originalAnchor: keepOriginal ? session.originalAnchor : null,
        originalFraction: keepOriginal ? session.originalFraction : 0,
      ),
    );
    final arrival = state.value?.currentAnchor;
    if (arrival != null) reportDisplayArrival(arrival);
    // 打开书、换章、重排之后都记一次位置：退出应用再进来能接着读
    unawaited(persist());
    if (!prefetch) return true;
    _prefetchNext(chapterIndex, options);
    _prefetchPrevious(chapterIndex, options);
    return true;
  }

  /// 内容偏移 → 页序：用章内百分比换算，够准且与排版无关
  int _pageForChapterOffset(ChapterLayout layout, int offset) {
    if (layout.totalLength <= 0 || layout.pageCount == 0) return 0;
    final fraction = (offset / layout.totalLength).clamp(0.0, 1.0);
    final index = (fraction * layout.pageCount).floor();
    return index.clamp(0, layout.pageCount - 1);
  }

  /// 预取下一章：让章末翻页不需要等待排版（界面上的「下一章首页」也用它）
  void _prefetchNext(int chapterIndex, LayoutOptions options) {
    final session = state.value;
    if (session == null) return;
    final nextIndex = chapterIndex + 1;
    traceTurn('prefetch next requested chapter=$nextIndex');
    if (nextIndex >= session.chapters.length) {
      _nextChapterLayout = null;
      return;
    }
    final chapter = session.chapters[nextIndex];
    final signature = options.layoutSignature;
    unawaited(() async {
      try {
        final content = await ref
            .read(chapterContentRepositoryProvider)
            .chapter(bookId, chapter);
        final layout = await ref
            .read(readerEngineProvider)
            .layoutChapter(
              LayoutRequest(
                bookId: bookId,
                contentVersion: session.book.contentVersion,
                chapter: chapter,
                content: content,
                options: options,
              ),
            );
        // 参数或书变了就丢弃这份预取
        final latest = state.value;
        if (latest == null ||
            latest.viewportSignature != signature ||
            latest.chapterIndex != chapterIndex) {
          return;
        }
        _nextChapterLayout = layout;
        traceTurn('prefetch next ready chapter=$nextIndex pages=${layout.pageCount}');
        // 通知一次界面：下一章的首页可以参与翻页过渡了（prefetch 不在 state 里，
        // 但拖动过渡要用到它）
        final current = state.value;
        if (current != null) state = AsyncData(current.copyWith());
      } on LayoutCancelled {
        // 参数变化导致作废，忽略
      } on Object catch (error) {
        if (ref.mounted && isSourceChange(error)) {
          ref.read(readerSourceChangeProvider(bookId).notifier).markChanged();
        }
        // 预取失败不影响当前阅读，真正翻页时会再试一次
      }
    }());
  }

  /// 预取上一章：章首往回拖动时能直接滑出上一章的最后一页。
  ///
  /// 跨章往回翻时上一章刚排过，通常直接命中排版缓存，代价可以忽略；
  /// 从目录跳到中间某章时则要排一次完整的上一章，和下一章预取同量级。
  void _prefetchPrevious(int chapterIndex, LayoutOptions options) {
    final session = state.value;
    if (session == null) return;
    final previousIndex = chapterIndex - 1;
    traceTurn('prefetch previous requested chapter=$previousIndex');
    if (previousIndex < 0) {
      _previousChapterLayout = null;
      return;
    }
    final chapter = session.chapters[previousIndex];
    final signature = options.layoutSignature;
    unawaited(() async {
      try {
        final content = await ref
            .read(chapterContentRepositoryProvider)
            .chapter(bookId, chapter);
        final layout = await ref
            .read(readerEngineProvider)
            .layoutChapter(
              LayoutRequest(
                bookId: bookId,
                contentVersion: session.book.contentVersion,
                chapter: chapter,
                content: content,
                options: options,
              ),
            );
        // 参数或书变了就丢弃这份预取
        final latest = state.value;
        if (latest == null ||
            latest.viewportSignature != signature ||
            latest.chapterIndex != chapterIndex) {
          return;
        }
        _previousChapterLayout = layout;
        traceTurn('prefetch previous ready chapter=$previousIndex pages=${layout.pageCount}');
        // 通知一次界面：上一章的最后一页可以参与翻页过渡了（prefetch 不在 state 里，
        // 但拖动过渡要用到它）
        final current = state.value;
        if (current != null) state = AsyncData(current.copyWith());
      } on LayoutCancelled {
        // 参数变化导致作废，忽略
      } on Object catch (error) {
        if (ref.mounted && isSourceChange(error)) {
          ref.read(readerSourceChangeProvider(bookId).notifier).markChanged();
        }
        // 预取失败不影响当前阅读，真正翻页时会再排一次
      }
    }());
  }

  /// 供测试直接构造预取结果
  void debugSetNextChapterLayout(ChapterLayout? layout) =>
      _nextChapterLayout = layout;
}
