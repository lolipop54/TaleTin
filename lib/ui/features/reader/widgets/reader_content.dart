part of '../views/reader_view.dart';

class _ReaderBody extends ConsumerStatefulWidget {
  const _ReaderBody({required this.bookId});

  final String bookId;

  @override
  ConsumerState<_ReaderBody> createState() => _ReaderBodyState();
}

class _ReaderBodyState extends ConsumerState<_ReaderBody> {
  ReaderState? _closingControls;
  Timer? _controlsExitTimer;
  bool _keepOriginal = false;
  String get bookId => widget.bookId;

  @override
  void initState() {
    super.initState();
    // 分页、滚动与扫描过渡都可能截图，工作区跟随整次阅读，而非某一章。
    unawaited(OriginalHostController.setCaptureEnabled(true));
  }

  @override
  void dispose() {
    _controlsExitTimer?.cancel();
    unawaited(OriginalHostController.setCaptureEnabled(false));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(readerProvider);
    ref.listen(readerProvider, (previous, next) {
      if (previous == null) return;
      if (previous.controlsVisible && !next.controlsVisible) {
        ref.read(readerProgressReturnProvider(bookId).notifier).controlsClosed();
      }
      if (previous.controlsVisible && !next.controlsVisible &&
          next.panel == ReaderPanel.none) {
        _controlsExitTimer?.cancel();
        // 普通控制层和一级面板都保留到滑出结束，不能关闭时直接销毁。
        // 保留原状态，避免工具面板退出中途重新出现进度区。
        if (!MediaQuery.disableAnimationsOf(context)) {
          setState(() => _closingControls = previous);
          _controlsExitTimer = Timer(readerPanelExitDuration, () {
            if (mounted) setState(() => _closingControls = null);
          });
        }
      } else if (next.controlsVisible || next.panel != ReaderPanel.none) {
        _controlsExitTimer?.cancel();
        _closingControls = null;
      }
    });
    final controlsState = state.controlsVisible ? state : _closingControls;
    // 阅读页持有查询，关闭/重开面板仍保留关键词、结果与列表位置。
    ref.watch(bookSearchProvider(bookId));
    ref.watch(bookSearchNavigationProvider(bookId));
    ref.watch(readerProgressReturnProvider(bookId));
    ref.listen(readerSessionProvider(bookId), (previous, next) {
      final beforeSession = previous?.value;
      final afterSession = next.value;
      final before = beforeSession?.currentAnchor;
      final after = afterSession?.currentAnchor;
      // 原书跨章会先清空旧锚点，再回填新章位置，不能只比较两个非空锚点。
      final chapterChanged = beforeSession != null && afterSession != null &&
          beforeSession.chapter.id != afterSession.chapter.id;
      final anchorChanged = before != null && after != null &&
          !before.samePosition(after);
      if (chapterChanged || anchorChanged) {
        ref.read(readerProgressReturnProvider(bookId).notifier).pageChanged();
        ref.read(bookSearchNavigationProvider(bookId).notifier).dismiss();
      }
    });
    ref.listen(readerProvider.select((s) => s.panel), (previous, next) {
      if (previous == ReaderPanel.search && next != ReaderPanel.search) {
        ref.read(bookSearchProvider(bookId).notifier).close();
      }
    });
    final automatic = ref.watch(automaticReadingProvider(bookId));
    final automaticController = ref.read(automaticReadingProvider(bookId).notifier);
    final scrolling = ref.watch(readerSessionProvider(bookId)).value?.scrolling == true;
    // 在阅读期间准备并保留索引，避免每次唤出面板先显示文件名再换成章名。
    final progressTitles = ref.watch(progressTitlesProvider(bookId));
    final settingsAsync = ref.watch(readerSettingsProvider(bookId));
    final loaded = settingsAsync.value;
    final session = ref.watch(readerSessionProvider(bookId)).value;
    if (loaded?.settings.layoutMode.isOriginal == true && session?.book.format == BookFormat.epub) {
      _keepOriginal = true;
    }
    // 本次阅读用过原书后保留内容对照表；切回原书复用，离开阅读页照常释放。
    if (_keepOriginal && session != null) ref.watch(originalLayoutProvider(bookId));
    // 本书设置还没读出来时先用全局偏好（启动时已读入）：主题不会闪一下默认色；
    // 正文等设置到位再排，避免按全局值排一遍再重排（AGENTS 规则 8）
    final settings =
        loaded ??
        ReaderSettingsState.fromGlobal(
          ref.watch(globalReadingPreferencesProvider),
        );
    final theme = settings.theme;

    return PopScope(
      // 分页和滚动都先保存最终位置，不能在路由已经销毁后读取 Provider。
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) {
          return;
        }
        // 返回结束自动任务，包含已暂停的扫描；撤图后再按普通阅读处理下一次返回。
        if (!state.controlsVisible && state.panel == ReaderPanel.none &&
            (automatic.running || automatic.preparing || automaticController.canResume)) {
          await automaticController.discard();
          return;
        }
        if (!state.controlsVisible && state.panel == ReaderPanel.none &&
            state.selection == null && state.note == null) {
          await ref.read(automaticReadingProvider(bookId).notifier).pause();
          await ref.read(readerSettingsProvider(bookId).notifier).pendingWrites;
          await ref.read(readerSessionProvider(bookId).notifier).flushPendingPosition();
          await ref.read(readingStatisticsServiceProvider).leaveVisual();
          if (!context.mounted) return;
          await prepareShelfReturn(ref);
          if (context.mounted) context.pop();
          return;
        }
        final vm = ref.read(readerProvider.notifier);
        // 先关笔记面板、再收选区、再收面板，最后才收起控制层（设计文档 4.1）
        if (state.note != null) {
          // 面板里可能还有没保存的想法：交给它自己问一句再关
          vm.requestCloseNoteEditor();
        } else if (state.selection != null) {
          vm.clearSelection();
        } else if (state.panel != ReaderPanel.none) {
          vm.closePanel();
        } else {
          vm.toggleControls();
        }
      },
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: theme.overlayBrightness == Brightness.dark
            ? SystemUiOverlayStyle.light
            : SystemUiOverlayStyle.dark,
        // 安全区底色与正文同样在200ms内过渡，避免屏幕边缘先跳到新主题。
        child: AnimatedContainer(
          duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : pageFadeDuration,
          color: theme.background,
          child: Scaffold(
          backgroundColor: Colors.transparent,
          // 键盘不压缩阅读页：正文与上下信息区都不跟着动，
          // 面板自己按键盘高度让位（ReaderSheet 处理），也不会触发整章重排
          resizeToAvoidBottomInset: false,
          body: Stack(
            children: [
              CompletionPromptHost(bookId: bookId),
              BookSearchPageHost(key: ValueKey('search-host-$bookId'), bookId: bookId),
              ReaderBookmarkLayer(bookId: bookId, paper: theme.background,
                allowPull: !scrolling && !state.controlsVisible && state.selection == null && state.note == null,
                topInset: (ref.watch(readingControlsProvider).value?.statusBar ?? true)
                    ? MediaQuery.paddingOf(context).top : 0,
                child: _ReadingContent(
                state: state,
                bookId: bookId,
                theme: theme,
                settings: settings,
                // 正文首次显示前也等真实章名索引，避免旧TXT补目录后页眉跳变。
                settingsReady: loaded != null && !progressTitles.isLoading,
              )),
              if (state.panel == ReaderPanel.none && !state.controlsVisible)
                SearchReturnBar(bookId: bookId, theme: theme, paintMenu: scrolling),
              // 控制层：顶部栏 + 底部工具栏
              if (controlsState != null) ...[
                // 控制栏打开时，正文任意空白处只负责收起，不能把点击透传成翻页。
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () =>
                        ref.read(readerProvider.notifier).toggleControls(),
                  ),
                ),
                if (controlsState.panel == ReaderPanel.none)
                  _TopBar(visible: state.controlsVisible,
                    state: controlsState, theme: theme, bookId: bookId),
                if (!progressTitles.isLoading)
                  _BottomControls(key: const ValueKey('reader-bottom-controls'),
                    visible: state.controlsVisible, state: controlsState, theme: theme, bookId: bookId),
              ],
              // 笔记面板：贴在键盘上方的一层，选区留着方便对照着写
              if (state.note != null) ...[
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => ref
                        .read(readerProvider.notifier)
                        .requestCloseNoteEditor(),
                  ),
                ),
                Align(
                  alignment: Alignment.bottomCenter,
                  child: Padding(
                    padding: EdgeInsets.only(
                      bottom: MediaQuery.viewInsetsOf(context).bottom,
                    ),
                    child: NoteEditorPanel(
                      bookId: bookId,
                      request: state.note!,
                    ),
                  ),
                ),
              ],
              // 子面板和遮罩共用当前阅读主题。
              if (state.panel != ReaderPanel.none && state.panel != ReaderPanel.search &&
                  !state.panelCovered)
                Positioned(left: 0, right: 0, top: 0,
                  bottom: readerPanelBottom(context), child: GestureDetector(
                  onTap: () => ref.read(readerProvider.notifier).closePanel(),
                  child: Container(color: ReaderSheet.scrimOf(context)),
                )),
              ReaderPanelViewport(
                child: ReaderPanelMotion(
                  panel: state.panel == ReaderPanel.none || state.panel == ReaderPanel.search ||
                      state.panelCovered ? null : state.panel,
                  delayOpening: !state.panelCovered,
                  child: state.panel == ReaderPanel.none || state.panel == ReaderPanel.search ||
                      state.panelCovered ? null : _buildPanel(ref, state),
                ),
              ),
            ],
          ),
        )),
      ),
    );
  }

  Widget _buildPanel(WidgetRef ref, ReaderState state) {
    switch (state.panel) {
      case ReaderPanel.contents:
        return PanelContents(state: state, bookId: bookId);
      case ReaderPanel.brightness:
        return PanelBrightness(bookId: bookId);
      case ReaderPanel.typography:
        // 排版模式开关只对 EPUB 显示，面板需要知道本书格式
        return PanelTypography(
          bookId: bookId,
          bookFormat: ref
              .watch(readerSessionProvider(bookId))
              .value
              ?.book
              .format,
        );
      case ReaderPanel.tts:
        return PanelTts(bookId: bookId);
      case ReaderPanel.auto:
        return PanelAuto(state: state, bookId: bookId);
      case ReaderPanel.search:
        return const SizedBox.shrink(); // 全文搜索由独立页面承载。
      case ReaderPanel.none:
        return const SizedBox.shrink();
    }
  }
}

/// 正文层：顶部章节信息 + 真实分页正文 + 底部状态行。
class _ReadingContent extends ConsumerStatefulWidget {
  const _ReadingContent({
    required this.state,
    required this.bookId,
    required this.theme,
    required this.settings,
    required this.settingsReady,
  });

  final ReaderState state;
  final String bookId;
  final ReadingTheme theme;

  /// 当前生效的阅读设置（本书设置没读出来时是全局偏好）
  final ReaderSettingsState settings;

  /// 本书设置是否已读出来
  final bool settingsReady;

  @override
  ConsumerState<_ReadingContent> createState() => _ReadingContentState();
}

class _ReadingContentState extends ConsumerState<_ReadingContent> {
  final _transitionKey = GlobalKey();
  late final ReaderProgressReturn _progressReturn;
  late final Future<void> Function() _prepareJumpCover;
  late final Future<void> Function() _finishJumpCover;
  final _originalKey = GlobalKey();
  final _pageKey = GlobalKey<_PageAreaState>();
  final _scrollKey = GlobalKey<OriginalScrollAreaState>();
  final _textScrollKey = GlobalKey<SimplifiedScrollAreaState>();
  Object? _reportedOriginalError;
  Size? _originalViewport;
  ReaderState get state => widget.state;
  String get bookId => widget.bookId;
  ReadingTheme get theme => widget.theme;
  ReaderSettingsState get settings => widget.settings;
  bool get settingsReady => widget.settingsReady;

  @override
  void initState() {
    super.initState();
    _progressReturn = ref.read(readerProgressReturnProvider(bookId).notifier);
    _prepareJumpCover = () => ReaderDisplayTransition.captureForJump(_transitionKey);
    _progressReturn.prepareJumpCover = _prepareJumpCover;
    _finishJumpCover = () => ReaderDisplayTransition.finishJump(_transitionKey);
    _progressReturn.finishJumpCover = _finishJumpCover;
  }

  @override
  void dispose() {
    if (_progressReturn.prepareJumpCover == _prepareJumpCover) {
      _progressReturn.prepareJumpCover = null;
      _progressReturn.finishJumpCover = null;
    }
    super.dispose();
  }

  Future<NativeReadingFrame?> _captureNative() async {
    if (_scrollKey.currentState != null) return OriginalScrollArea.capture(_scrollKey);
    if (_originalKey.currentState != null) return OriginalReaderArea.capture(_originalKey);
    return null;
  }

  bool _displayReady() {
    // 失败页也是准备结束，不能继续盖着加载动画隐藏真正的错误。
    final session = ref.read(readerSessionProvider(bookId));
    if (session.hasError && !session.isLoading) return true;
    if (ref.read(readerSessionProvider(bookId).notifier).displayTarget != null) return false;
    if (_scrollKey.currentState case final scroll?) return scroll.isReady;
    if (_textScrollKey.currentState case final scroll?) return scroll.isReady;
    if (_originalKey.currentState != null) return OriginalReaderArea.ready(_originalKey);
    return _pageKey.currentState?.isReady ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final sessionAsync = ref.watch(readerSessionProvider(bookId));
    final session = sessionAsync.value;
    final searchBusy = ref.watch(bookSearchNavigationProvider(bookId).select((s) => s.busy));
    final jumpBusy = ref.watch(readerProgressReturnProvider(bookId).select((s) => s.busy));
    return ReadingStatisticsScope(bookId: bookId,
      onVolumeTurn: (forward) async {
        if (_textScrollKey.currentState case final scroll?) {
          await scroll.volumeTurn(forward);
        } else if (_scrollKey.currentState case final scroll?) {
          await scroll.volumeTurn(forward);
        } else if (_originalKey.currentState != null) {
          await OriginalReaderArea.turn(_originalKey, forward);
        } else { await _pageKey.currentState?.volumeTurn(forward); }
      },
      ready: () => settingsReady && _displayReady() &&
        !ref.read(readerSessionProvider(bookId)).hasError &&
        ref.read(readerSessionProvider(bookId)).value?.currentAnchor != null,
      child: SafeArea(
      top: ref.watch(readingControlsProvider).value?.statusBar ?? true,
      bottom: ref.watch(readingControlsProvider).value?.navigationBar ?? true,
      // 显示系统栏时避开对应安全区；隐藏时，两种排版的画布和手势一起延伸。
      // 键盘收起的中间帧也保留导航栏留白，正文不先变高再缩回。
      maintainBottomViewPadding: true,
      child: Stack(
        children: [
          Positioned.fill(child: LayoutBuilder(builder: (context, constraints) {
            final originalPaged = settings.settings.layoutMode.isOriginal &&
                settings.settings.pageTurnEffect != PageTurnEffect.scroll;
            if (MediaQuery.viewInsetsOf(context).bottom == 0) {
              _originalViewport = constraints.biggest;
            }
            return ReaderDisplayTransition(
            key: _transitionKey,
            appearance: theme,
            loadingRevision: settings.settings.layoutMode,
            onReadable: ReaderPageReady.of(context),
            viewport: originalPaged ? _originalViewport : null,
            reflow: originalPaged ? (settings.settings.fontSize,
              settings.settings.fontFamily, settings.settings.useOriginalFont,
              settings.settings.bold, settings.settings.indent,
              settings.settings.lineHeight, settings.settings.paragraphGapEm,
              settings.settings.horizontalPadding, settings.settings.pageTurnEffect,
              theme, MediaQuery.textScalerOf(context),
              ref.watch(statusInfoVisibleProvider).value) : searchBusy,
            display: (settings.settings.layoutMode,
              settings.settings.pageTurnEffect == PageTurnEffect.scroll),
            ready: () => !searchBusy && !jumpBusy && _displayReady(), captureNative: _captureNative,
            loadingBackground: theme.background,
            child: ReaderPerformance(
              label: '${settings.settings.layoutMode.name}.${settings.settings.pageTurnEffect.name}',
              child: _body(context, ref, sessionAsync, session)));
          })),
          // 一次性提示（全书首尾、原书排版不可用）：两种排版模式共用一处显示
          if (state.notice != null)
            Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: const EdgeInsets.only(bottom: GtSpacing.s6),
                child: _ReaderNotice(
                  key: ValueKey(state.noticeToken),
                  text: state.notice!,
                ),
              ),
            ),
        ],
      ),
    ));
  }

  Widget _body(
    BuildContext context,
    WidgetRef ref,
    AsyncValue<ReaderSession> sessionAsync,
    ReaderSession? session,
  ) {
    if (sessionAsync.hasError && !sessionAsync.isLoading) {
      return _ErrorState(
        message: '${sessionAsync.error}',
        onRetry: () => ref.invalidate(readerSessionProvider(bookId)),
      );
    }
    if (session == null) return const _PreparingState();
    // 本书的排版设置还没到位：先不排，否则会按全局值排一遍再重排
    if (!settingsReady) return const _PreparingState();
    if (settings.settings.pageTurnEffect == PageTurnEffect.scroll) {
      final annotations = ref.watch(annotationsProvider(bookId));
      if (!annotations.hasValue && annotations.isLoading) return const _PreparingState();
    }

    if (settings.settings.pageTurnEffect == PageTurnEffect.scroll &&
        (!settings.settings.layoutMode.isOriginal || session.book.format != BookFormat.epub)) {
      return SimplifiedScrollArea(key: _textScrollKey,
          bookId: bookId, session: session, settings: settings);
    }

    // 原书排版模式：EPUB 且用户选了原书排版时走 WebView
    if (settings.settings.layoutMode.isOriginal &&
        session.book.format == BookFormat.epub) {
      final original = ref.watch(originalLayoutProvider(bookId));
      // 原书内容打不开（源文件缺失、与章节索引对不上）：降级回简化排版，
      // 并把原因告诉用户，而不是留一个空白页（计划 3.1）
      if (original.hasError && !original.isLoading) {
        if (_reportedOriginalError != original.error) {
          _reportedOriginalError = original.error;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            ref.read(readerSessionProvider(bookId).notifier).setLayoutMode(ReadingLayoutMode.simplified);
            ref.read(readerProvider.notifier).showNotice('原书内容无法读取，已用简化排版显示');
          });
        }
        if (settings.settings.pageTurnEffect == PageTurnEffect.scroll) {
          return SimplifiedScrollArea(bookId: bookId, session: session, settings: settings);
        }
        return _PageArea(
          key: _pageKey,
          state: state,
          bookId: bookId,
          session: session,
          settings: settings,
        );
      }
      final controller = original.value;
      if (controller == null) return const _PreparingState();
      if (settings.settings.pageTurnEffect == PageTurnEffect.scroll) {
        return OriginalScrollArea(key: _scrollKey, bookId: bookId, session: session,
            settings: settings, original: controller);
      }
      return OriginalReaderArea(
        key: _originalKey,
        bookId: bookId,
        session: session,
        controller: controller,
        settings: settings.settings,
        theme: settings.theme,
        onCenterTap: () => ref.read(automaticReadingProvider(bookId).notifier).centerTap(),
      );
    }
    // 还没排完版时也走排版区：它负责把当前尺寸与设置交给引擎
    return _PageArea(
      key: _pageKey,
      state: state,
      bookId: bookId,
      session: session,
      settings: settings,
    );
  }
}
