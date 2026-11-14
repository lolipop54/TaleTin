part of 'reader_session_view_model.dart';

/// 集中章节排版、相邻章预取和过期结果丢弃，状态仍由主 Notifier 提交。
mixin _ReaderLayoutCoordinator on AsyncNotifier<ReaderSession> {
  StreamSubscription<ChapterLayout>? _layoutUpdates;
  ChapterLayout? _observedLayout;
  ChapterLayoutTask? _displayLayoutTask;
  void Function()? _releaseDisplayLayoutTask;
  final _neighborPreparations = <Object, Future<ChapterLayout>>{};

  /// 已交付的页仍可能需要继续补排，后台暂停时也要保留当前任务。
  void _retainDisplayLayout(ReaderSession? session) {
    final task = !_mode.isOriginal && session?.scrolling == false
        ? session?.layout?.task
        : null;
    if (identical(task, _displayLayoutTask)) return;
    final releasePrevious = _releaseDisplayLayoutTask;
    _releaseDisplayLayoutTask = task?.retainForDisplay();
    _displayLayoutTask = task;
    releasePrevious?.call();
  }

  /// 切章入口共用的排版失效处理：旧邻章和未完成请求必须一起失效。
  /// 听书追赶不经过手动排版入口，也不能继续沿用追赶前的翻页材料。
  LayoutToken _invalidateLayoutRequests() {
    _observedLayout?.task?.pauseBackground();
    _token?.cancel();
    final token = _token = LayoutToken(++_tokenVersion);
    _nextChapterLayout = null;
    _previousChapterLayout = null;
    return token;
  }

  /// 预取和动画准备的排版只能交给同一本书、同一目标章及同一版式。
  ChapterLayout? _matchingChapterLayout(
    ChapterLayout? layout,
    ReaderSession session,
    int index,
    LayoutOptions options,
  ) =>
      layout != null &&
          layout.task?.isDisposed != true &&
          layout.bookId == session.book.id &&
          layout.contentVersion == session.book.contentVersion &&
          layout.chapterId == session.chapters[index].id &&
          layout.options.layoutSignature == options.layoutSignature
      ? layout
      : null;

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
        final bySection = await _layoutIndexedTxt(
          session,
          index,
          options,
          atEnd: atEnd,
          token: _token,
        );
        if (!ref.mounted || _tokenVersion != version) {
          throw const LayoutCancelled(
            LayoutCancellationReason.requestSuperseded,
          );
        }
        if (bySection != null) return bySection;
        final chapter = session.chapters[index];
        final contents = ref.read(chapterContentRepositoryProvider);
        final txt = session.book.format == BookFormat.txt;
        final content = await (txt
            ? contents.chapterForProgressLayout(bookId, chapter)
            : contents.chapter(bookId, chapter));
        if (!ref.mounted || _tokenVersion != version) {
          throw const LayoutCancelled(
            LayoutCancellationReason.requestSuperseded,
          );
        }
        final request = LayoutRequest(
          bookId: bookId,
          contentVersion: session.book.contentVersion,
          chapter: chapter,
          content: content,
          options: options,
        );
        final engine = ref.read(readerEngineProvider);
        final layout =
            await (full && !(txt && chapter.textLength >= kLongTxtChapterLength)
                ? engine.layoutChapter(request)
                : engine.layoutWindow(request, atEnd: atEnd));
        if (!ref.mounted || _tokenVersion != version) {
          throw const LayoutCancelled(
            LayoutCancellationReason.requestSuperseded,
          );
        }
        return layout;
      } finally {
        _neighborPreparations.remove(key);
      }
    });
  }

  Future<ChapterLayout?> _layoutIndexedTxt(
    ReaderSession session,
    int index,
    LayoutOptions options, {
    Locator? target,
    int? chapterOffset,
    bool atEnd = false,
    bool targetFirst = false,
    LayoutToken? token,
  }) async {
    final chapter = session.chapters[index];
    if (session.book.format != BookFormat.txt ||
        session.scrolling ||
        chapter.textLength < kLongTxtChapterLength) {
      return null;
    }
    final source = await ref
        .read(chapterContentRepositoryProvider)
        .txtChapterSource(bookId, chapter);
    if (!ref.mounted || token?.isCancelled == true) {
      throw const LayoutCancelled();
    }
    if (source == null) return null;
    return ref
        .read(readerEngineProvider)
        .layoutWindow(
          LayoutRequest.txtSections(
            bookId: bookId,
            contentVersion: session.book.contentVersion,
            chapter: chapter,
            source: source,
            options: options,
            targetFirst: targetFirst,
            chapterOffset: target == null ? chapterOffset : null,
          ),
          target: target,
          atEnd: atEnd,
          token: token,
        );
  }

  void _watchLayout(ChapterLayout layout) {
    _observedLayout?.task?.pauseBackground();
    _observedLayout = layout;
    unawaited(_layoutUpdates?.cancel());
    _layoutUpdates = layout.updates.listen((updated) {
      final latest = state.value;
      if (!ref.mounted ||
          latest == null ||
          latest.layout?.identity != updated.identity ||
          !updated.samePageAs(latest.layout, latest.pageIndex)) {
        return;
      }
      // 后文只能补索引；不选择目标、不回报落点、不保存当前位置。
      state = AsyncData(latest.copyWith(layout: updated));
    });
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
    if (!session.layout!.isComplete || session.layout!.hasLaterTxtWindow) {
      return null;
    }
    final index = session.chapterIndex + 1;
    final next = index >= session.chapters.length
        ? null
        : _matchingChapterLayout(
            _nextChapterLayout,
            session,
            index,
            session.layout!.options,
          );
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
      if (session.layout!.page(session.pageIndex - 1) == null) return null;
      return (layout: session.layout!, pageIndex: session.pageIndex - 1);
    }
    final index = session.chapterIndex - 1;
    final previous = index < 0
        ? null
        : _matchingChapterLayout(
            _previousChapterLayout,
            session,
            index,
            session.layout!.options,
          );
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
    final adjacent = await session.layout!.adjacentPage(
      session.pageIndex,
      forward: forward,
    );
    if (!current()) return null;
    if (adjacent != null) return adjacent;
    if (!forward && session.pageIndex > 0) return null;
    final index = session.chapterIndex + (forward ? 1 : -1);
    if (index < 0 || index >= session.chapters.length) return null;
    final ChapterLayout layout;
    try {
      layout = await _prepareNeighborChapter(
        session,
        index,
        options,
        atEnd: !forward,
      );
    } on LayoutCancelled {
      // 听书追赶或新导航已经改变页面，旧手势准备正常结束即可。
      return null;
    }
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
    bool targetFirst = false,
  }) async {
    final session = state.value;
    if (session == null || options == null) return false;
    final chapter = session.chapters[chapterIndex];
    final contents = ref.read(chapterContentRepositoryProvider);
    final engine = ref.read(readerEngineProvider);
    final txt = session.book.format == BookFormat.txt;
    final deliverTargetFirst =
        targetFirst || (txt && chapter.textLength >= kLongTxtChapterLength);

    final token = _invalidateLayoutRequests();

    final ChapterLayout layout;
    ChapterContent? content;
    Locator? target = anchor;
    final matching = _matchingChapterLayout(
      preparedLayout,
      session,
      chapterIndex,
      options,
    );
    // 读取正式正文时仍可能有别的排版请求，先保护已选中的预取结果。
    final releaseMatching = matching?.task?.retainForDisplay();
    try {
      final indexed = matching?.readsTxtBySection == true
          ? matching
          : await _layoutIndexedTxt(
              session,
              chapterIndex,
              options,
              target: anchor,
              chapterOffset: chapterOffset,
              atEnd: atChapterEnd,
              targetFirst: deliverTargetFirst,
              token: token,
            );
      if (indexed != null) {
        layout = indexed;
        if (target == null && chapterOffset != null) {
          target = layout.txtLocatorAtOffset(chapterOffset);
        }
      } else {
        // PDF原页只需定位数据；电子书排版前仍须经过仓库准备真实图片。
        content =
            session.book.format != BookFormat.pdf &&
                chapterIndex == session.chapterIndex &&
                session.content != null
            ? session.content!
            : await (txt ||
                      (deliverTargetFirst &&
                          session.book.format.usesOriginalWebView)
                  ? contents.chapterForProgressLayout(bookId, chapter)
                  : contents.chapter(bookId, chapter));
        if (token.isCancelled) return false;
        if (target == null &&
            chapterOffset != null &&
            ReaderDeliveryExperiments.contentTarget) {
          target = locatorForFraction(
            content: content,
            bookId: bookId,
            contentVersion: session.book.contentVersion,
            chapterId: chapter.id,
            fraction: content.textLength == 0
                ? 0
                : chapterOffset / content.textLength,
          );
        }
        final request = LayoutRequest(
          bookId: bookId,
          contentVersion: session.book.contentVersion,
          chapter: chapter,
          content: content,
          options: options,
          targetFirst: deliverTargetFirst,
          allowPageRestart:
              chapterOffset != null &&
              !_mode.isOriginal &&
              !session.scrolling &&
              session.book.format.usesOriginalWebView,
        );
        layout =
            matching ??
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
      }
    } on LayoutCancelled {
      return false;
    } on Object catch (error, stack) {
      if (!token.isCancelled && ref.mounted) state = AsyncError(error, stack);
      return false;
    } finally {
      releaseMatching?.call();
    }
    if (token.isCancelled) return false;

    final pageIndex = switch ((target, chapterOffset, atChapterEnd)) {
      (final Locator target, _, _) => layout.pageIndexOf(target) ?? 0,
      (_, final int offset, _) => _pageForChapterOffset(layout, offset),
      // 空章节（没有正文，比如封面页）没有页，落回第 0 页而不是 -1
      (_, _, true) => layout.pageCount == 0 ? 0 : layout.pageCount - 1,
      _ => 0,
    };

    // 首屏还要等可直接翻到的跨章页，期间新的当前章不能被回收。
    final releasePreparingLayout = layout.task?.retainForDisplay();
    try {
      // PDF一页就是一个内部章。跳转先显示目标页，不等待两侧扫描页提图；
      // 后面的预取仍准备相邻页，用户立刻翻页时也沿用等待目标就绪的流程。
      if (ReaderDeliveryExperiments.incremental &&
          prefetch &&
          !deliverTargetFirst &&
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
        if (pageIndex == 0 &&
            chapterIndex > 0 &&
            _canPrefetchChapter(session, chapterIndex - 1)) {
          final previous = await neighbor(chapterIndex - 1, true);
          if (token.isCancelled) return false;
          _previousChapterLayout = previous;
        }
        if (layout.isComplete &&
            !layout.hasLaterTxtWindow &&
            pageIndex + 1 >= layout.pageCount &&
            chapterIndex + 1 < session.chapters.length &&
            _canPrefetchChapter(session, chapterIndex + 1)) {
          final next = await neighbor(chapterIndex + 1, false);
          if (token.isCancelled) return false;
          _nextChapterLayout = next;
        }
        if (token.isCancelled) return false;
      }
    } on LayoutCancelled {
      return false;
    } finally {
      releasePreparingLayout?.call();
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
        content: layout.readsTxtBySection
            ? null
            : txt
            ? layout.content
            : content,
        layout: layout,
        pageIndex: pageIndex.clamp(layout.firstPage, layout.pageCount - 1),
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

  // 超长 TXT 的转换与用户跳转共用正文后台任务。留给真正的翻页或跳转请求，
  // 防止刚到目标页就排队解码两侧长章，拖慢随后返回或再次跳转。
  bool _canPrefetchChapter(ReaderSession session, int index) =>
      session.book.format != BookFormat.txt ||
      session.chapters[index].textLength < kLongTxtChapterLength;

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
    if (!_canPrefetchChapter(session, nextIndex)) return;
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
    if (!_canPrefetchChapter(session, previousIndex)) return;
    bool hasPreparedPrevious() =>
        _matchingChapterLayout(
          _previousChapterLayout,
          session,
          previousIndex,
          options,
        ) !=
        null;
    if (hasPreparedPrevious()) return;
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
        if (hasPreparedPrevious()) return;
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
