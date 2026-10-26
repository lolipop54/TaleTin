part of 'reader_session_view_model.dart';

/// 集中章节排版、相邻章预取和过期结果丢弃，状态仍由主 Notifier 提交。
mixin _ReaderLayoutCoordinator on AsyncNotifier<ReaderSession> {
  StreamSubscription<ChapterLayout>? _layoutUpdates;
  ChapterLayout? _observedLayout;
  final _neighborPreparations = <Object, Future<ChapterLayout>>{};

  /// 预取和用户翻页同时请求同一邻章时，共用正文准备与排版任务。
  Future<ChapterLayout> _prepareNeighborChapter(
    ReaderSession session,
    int index,
    LayoutOptions options, {
    bool atEnd = false,
    bool full = false,
  }) {
    final version = _tokenVersion;
    final key = (
      version,
      session.chapters[index].id,
      options.layoutSignature,
      atEnd,
      full,
    );
    return _neighborPreparations.putIfAbsent(key, () async {
      try {
        final chapter = session.chapters[index];
        final content = await ref
            .read(chapterContentRepositoryProvider)
            .chapter(bookId, chapter);
        if (!ref.mounted || _tokenVersion != version) {
          throw const LayoutCancelled();
        }
        final request = LayoutRequest(
          bookId: bookId,
          contentVersion: session.book.contentVersion,
          chapter: chapter,
          content: content,
          options: options,
        );
        final engine = ref.read(readerEngineProvider);
        return await (full
            ? engine.layoutChapter(request)
            : engine.layoutWindow(request, atEnd: atEnd));
      } finally {
        _neighborPreparations.remove(key);
      }
    });
  }

  void _watchLayout(ChapterLayout layout) {
    _observedLayout?.task?.pauseBackground();
    _observedLayout = layout;
    unawaited(_layoutUpdates?.cancel());
    _layoutUpdates = layout.updates.listen((updated) {
      final latest = state.value;
      if (!ref.mounted || latest?.layout?.identity != updated.identity) return;
      // 后文只能补索引；不选择目标、不回报落点、不保存当前位置。
      state = AsyncData(latest!.copyWith(layout: updated));
    });
  }

  Future<void> _ensureForwardPage() async {
    final before = state.value;
    final layout = before?.layout;
    if (before == null ||
        layout == null ||
        layout.isComplete ||
        before.pageIndex + 1 < layout.pageCount) {
      return;
    }
    final prepared = await layout.ensurePage(before.pageIndex + 1);
    final latest = state.value;
    if (!ref.mounted ||
        latest?.layout?.identity != layout.identity ||
        latest?.pageIndex != before.pageIndex) {
      return;
    }
    state = AsyncData(latest!.copyWith(layout: prepared));
  }

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
  void cancelProgressNavigation();
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
    if (_options != null &&
        _options!.layoutSignature != options.layoutSignature) {
      cancelProgressNavigation();
    }
    final unchanged =
        session.isReady &&
        session.viewportSignature == options.layoutSignature &&
        _options?.layoutSignature == options.layoutSignature;
    if (!unchanged && ReaderRecoveryDiagnostics.observing) {
      ReaderRecoveryDiagnostics.record('applyViewport', {
        'width': options.contentWidth,
        'height': options.contentHeight,
        'previousWidth': _options?.contentWidth,
        'previousHeight': _options?.contentHeight,
        'paginate': paginate,
        'prefetch': prefetch,
        'chapter': session.chapterIndex,
        'page': session.pageIndex,
        'fontSize': options.settings.fontSize,
        'lineHeight': options.settings.lineHeight,
        'signatureChanged':
            _options?.layoutSignature != options.layoutSignature,
      });
    }
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
      anchor:
          displayTarget ??
          restored?.locator ??
          session.currentAnchor ??
          _pendingAnchor,
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
    if (!session.layout!.isComplete) return null;
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
    final session = state.value, options = _options;
    if (session == null || options == null) return null;
    final version = _tokenVersion;
    bool current() =>
        ref.mounted &&
        _tokenVersion == version &&
        state.value?.chapterIndex == session.chapterIndex &&
        state.value?.pageIndex == session.pageIndex &&
        _options?.layoutSignature == options.layoutSignature;
    if (cached != null) {
      if (session.book.format == BookFormat.pdf) {
        // 排版还在内存中，不代表可重建的扫描图片仍在磁盘缓存中。
        // 翻页解码前补齐并保护图片，保留动画已使用的同一份排版。
        final chapter = session.chapters.firstWhere(
          (c) => c.id == cached.layout.chapterId,
        );
        await ref
            .read(chapterContentRepositoryProvider)
            .chapter(bookId, chapter);
      }
      return current() ? cached : null;
    }
    if (forward && !session.layout!.isComplete) {
      final layout = await session.layout!.ensurePage(session.pageIndex + 1);
      if (!current()) return null;
      if (session.pageIndex + 1 < layout.pageCount) {
        return (layout: layout, pageIndex: session.pageIndex + 1);
      }
    }
    final index = session.chapterIndex + (forward ? 1 : -1);
    if (index < 0 || index >= session.chapters.length) return null;
    final layout = await _prepareNeighborChapter(
      session,
      index,
      options,
      atEnd: !forward,
    );
    if (current()) {
      // 动画和落页共用这一份页片段，不能在提交时重新生成另一份排版。
      if (forward) {
        _nextChapterLayout = layout;
      } else {
        _previousChapterLayout = layout;
      }
    } else {
      return null;
    }
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
    ChapterLayout? preparedLayout,
  }) async {
    final session = state.value;
    if (session == null || options == null) return false;
    final chapter = session.chapters[chapterIndex];
    final contents = ref.read(chapterContentRepositoryProvider);
    final engine = ref.read(readerEngineProvider);

    // 旧排版作废：切章或改参数后回来的结果不再上屏
    _observedLayout?.task?.pauseBackground();
    final token = LayoutToken(++_tokenVersion);
    _token?.cancel();
    _token = token;

    // 相邻章的预取结果一并作废：换了章或改了参数，旧的相邻页会画错内容。
    // 先清掉，等这次排版完成后的新预取填回来。
    _nextChapterLayout = null;
    _previousChapterLayout = null;

    final ChapterContent content;
    try {
      // PDF原页只需定位数据；电子书排版前仍须经过仓库准备真实图片。
      content =
          session.book.format != BookFormat.pdf &&
              chapterIndex == session.chapterIndex &&
              session.content != null
          ? session.content!
          : await contents.chapter(bookId, chapter);
    } on Object catch (error, stack) {
      if (!token.isCancelled) {
        state = AsyncError(error, stack);
      }
      return false;
    }
    if (token.isCancelled) return false;

    final ChapterLayout layout;
    final target =
        anchor ??
        (chapterOffset == null || !ReaderDeliveryExperiments.contentTarget
            ? null
            : locatorForFraction(
                content: content,
                bookId: bookId,
                contentVersion: session.book.contentVersion,
                chapterId: chapter.id,
                fraction: content.textLength == 0
                    ? 0
                    : chapterOffset / content.textLength,
              ));
    try {
      final request = LayoutRequest(
        bookId: bookId,
        contentVersion: session.book.contentVersion,
        chapter: chapter,
        content: content,
        options: options,
      );
      layout =
          preparedLayout ??
          await traceTurnStep(
            'load simplified-layout',
            () =>
                chapterOffset != null &&
                    !ReaderDeliveryExperiments.contentTarget
                ? engine.layoutChapter(request, token: token)
                : engine.layoutWindow(
                    request,
                    target: target,
                    atEnd: atChapterEnd,
                    token: token,
                  ),
          );
    } on LayoutCancelled {
      return false;
    }
    if (token.isCancelled) return false;

    final pageIndex = switch ((target, chapterOffset, atChapterEnd)) {
      (final Locator target, _, _) => layout.pageIndexOf(target) ?? 0,
      (_, final int offset, _) => _pageForChapterOffset(layout, offset),
      // 空章节（没有正文，比如封面页）没有页，落回第 0 页而不是 -1
      (_, _, true) => layout.pageCount == 0 ? 0 : layout.pageCount - 1,
      _ => 0,
    };

    try {
      // PDF一页就是一个内部章。跳转先显示目标页，不等待两侧扫描页提图；
      // 后面的预取仍准备相邻页，用户立刻翻页时也沿用等待目标就绪的流程。
      if (ReaderDeliveryExperiments.incremental &&
          prefetch &&
          session.book.format != BookFormat.pdf) {
        Future<ChapterLayout> neighbor(int index, bool atEnd) async {
          final nextChapter = session.chapters[index];
          final nextContent = await contents.chapter(bookId, nextChapter);
          return engine.layoutWindow(
            LayoutRequest(
              bookId: bookId,
              contentVersion: session.book.contentVersion,
              chapter: nextChapter,
              content: nextContent,
              options: options,
            ),
            atEnd: atEnd,
            token: token,
          );
        }

        // 只把直接可翻到的跨章页列为首屏必需，普通中部目标不排无关前章。
        if (pageIndex == 0 && chapterIndex > 0) {
          _previousChapterLayout = await neighbor(chapterIndex - 1, true);
        }
        if (layout.isComplete &&
            pageIndex + 1 >= layout.pageCount &&
            chapterIndex + 1 < session.chapters.length) {
          _nextChapterLayout = await neighbor(chapterIndex + 1, false);
        }
        if (token.isCancelled) return false;
      }
    } on LayoutCancelled {
      return false;
    }

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
        originalContentProgress:
            keepOriginal && session.originalContentProgress,
      ),
    );
    _watchLayout(layout);
    final arrival = state.value?.currentAnchor;
    if (arrival != null) reportDisplayArrival(arrival);
    // 打开书、换章、重排之后都记一次位置：退出应用再进来能接着读
    unawaited(persist());
    if (!prefetch) return true;
    _prefetchNext(chapterIndex, options);
    if (!ReaderDeliveryExperiments.incremental || pageIndex == 0) {
      _prefetchPrevious(chapterIndex, options);
    }
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
    final signature = options.layoutSignature;
    final version = _tokenVersion;
    unawaited(() async {
      try {
        final layout = await _prepareNeighborChapter(
          session,
          nextIndex,
          options,
        );
        // 参数或书变了就丢弃这份预取
        final latest = state.value;
        if (_tokenVersion != version ||
            latest == null ||
            latest.viewportSignature != signature ||
            latest.chapterIndex != chapterIndex) {
          return;
        }
        _nextChapterLayout = layout;
        traceTurn(
          'prefetch next ready chapter=$nextIndex pages=${layout.pageCount}',
        );
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
    if (_previousChapterLayout?.chapterId == chapter.id) return;
    final signature = options.layoutSignature;
    final version = _tokenVersion;
    unawaited(() async {
      try {
        final layout = await _prepareNeighborChapter(
          session,
          previousIndex,
          options,
          atEnd: true,
          full: session.book.format != BookFormat.pdf,
        );
        // 参数或书变了就丢弃这份预取
        final latest = state.value;
        if (_tokenVersion != version ||
            latest == null ||
            latest.viewportSignature != signature ||
            latest.chapterIndex != chapterIndex) {
          return;
        }
        // 手势可能已经准备了上一页；迟到的预取不能把动画的页片段换掉。
        if (_previousChapterLayout?.chapterId == chapter.id) return;
        _previousChapterLayout = layout;
        traceTurn(
          'prefetch previous ready chapter=$previousIndex pages=${layout.pageCount}',
        );
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
