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
    ReaderWorkTrace.start('reader.body.dispose', {'bookId': bookId})?.finish();
    _controlsExitTimer?.cancel();
    unawaited(OriginalHostController.setCaptureEnabled(false));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sourceChanged =
        ref.watch(readerSourceChangeProvider(bookId)) ||
        isSourceChange(ref.watch(readerSessionProvider(bookId)).error);
    ref.listen(readerSessionProvider(bookId), (_, value) {
      if (isSourceChange(value.error)) {
        ref.read(readerSourceChangeProvider(bookId).notifier).markChanged();
      }
    });
    final state = ref.watch(readerProvider);
    // 保持动画任务存活到退出结束；简化排版即使没有原书显示器也要避让。
    ref.listen(readerControlsMotionProvider, (_, _) {});
    ref.listen(readerProvider, (previous, next) {
      if (previous == null) return;
      if (!MediaQuery.disableAnimationsOf(context) &&
          (previous.controlsVisible != next.controlsVisible ||
              previous.panel != next.panel ||
              previous.panelCovered != next.panelCovered)) {
        ReaderWorkTrace.start('reader.controls.change', {
          'visible': next.controlsVisible,
          'panel': next.panel.name,
          'covered': next.panelCovered,
        })?.finish();
        ref
            .read(readerControlsMotionProvider.notifier)
            .begin(
              next.controlsVisible
                  ? readerPanelEnterDuration + readerProgressCollapseDuration
                  : readerPanelExitDuration,
            );
      }
      if (previous.controlsVisible && !next.controlsVisible) {
        ref
            .read(readerProgressReturnProvider(bookId).notifier)
            .controlsClosed();
      }
      if (previous.controlsVisible &&
          !next.controlsVisible &&
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
      final chapterChanged =
          beforeSession != null &&
          afterSession != null &&
          beforeSession.chapter.id != afterSession.chapter.id;
      final anchorChanged =
          before != null && after != null && !before.samePosition(after);
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
    final automaticController = ref.read(
      automaticReadingProvider(bookId).notifier,
    );
    final scrolling =
        ref.watch(readerSessionProvider(bookId)).value?.scrolling == true;
    // 在阅读期间准备并保留索引，避免每次唤出面板先显示文件名再换成章名。
    final progressTitles = ref.watch(progressTitlesProvider(bookId));
    final settingsAsync = ref.watch(readerSettingsProvider(bookId));
    final loaded = settingsAsync.value;
    final session = ref.watch(readerSessionProvider(bookId)).value;
    final showStatusBar =
        ref.watch(readingControlsProvider).value?.statusBar ?? true;
    if (loaded?.settings.layoutMode.isOriginal == true &&
        session?.book.format.usesOriginalWebView == true) {
      _keepOriginal = true;
    }
    // 本次阅读用过原书后保留内容对照表；切回原书复用，离开阅读页照常释放。
    if (_keepOriginal && session != null) {
      ref.watch(originalLayoutProvider(bookId));
    }
    // 本书设置还没读出来时先用全局偏好（启动时已读入）：主题不会闪一下默认色；
    // 正文等设置到位再排，避免按全局值排一遍再重排（AGENTS 规则 8）
    final settings =
        loaded ??
        ReaderSettingsState.fromGlobal(
          ref.watch(globalReadingPreferencesProvider),
        );
    final bars = ref.watch(readingControlsProvider).value;
    final media = MediaQuery.of(context);
    final edgeToEdge =
        !settings.pdfMode &&
        settings.settings.landscape &&
        media.size.width > media.size.height &&
        bars?.statusBar == false &&
        bars?.navigationBar == false;
    // 全屏横屏的纸面延伸到屏幕边缘；摄像头占位转为正文页边距，
    // 只影响这次显示，不把设备安全区写进用户保存的排版设置。
    final safeMargin = math.max(media.padding.left, media.padding.right);
    final pageSettings = edgeToEdge && safeMargin > 0
        ? ReaderSettingsState(
            settings: settings.fontSettings.copyWith(
              horizontalPadding: math.max(
                settings.fontSettings.horizontalPadding,
                safeMargin + 8,
              ),
            ),
            theme: settings.theme,
            pdf: settings.pdf,
            brightness: settings.brightness,
            customBrightness: settings.customBrightness,
          )
        : settings;
    final theme = settings.theme;
    // 保存当前显示配置快照，框架在构建子面板时抛错也能知道当时阅读方式。
    AppErrors.reporter.context = {
      'layout': settings.settings.layoutMode.name,
      'turnEffect': settings.settings.pageTurnEffect.name,
      'fontFamily': settings.settings.fontFamily,
      'fontSize': settings.settings.fontSize,
      'controls': state.controlsVisible,
      'panel': state.panel.name,
      'landscape': settings.settings.landscape,
      'spread': settings.settings.spreadEnabled,
      'bookEdges': settings.settings.bookEdges,
    };

    return PopScope(
      // 分页和滚动都先保存最终位置，不能在路由已经销毁后读取 Provider。
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        ReaderWorkTrace.start('reader.back.system', {
          'bookId': bookId,
          'didPop': didPop,
          'controls': state.controlsVisible,
          'panel': state.panel.name,
          'sourceChanged': sourceChanged,
        })?.finish();
        if (sourceChanged) return; // 刷新层负责等待保存和退出，避免执行两次返回。
        if (didPop) {
          return;
        }
        // 返回结束自动任务，包含已暂停的扫描；撤图后再按普通阅读处理下一次返回。
        if (!state.controlsVisible &&
            state.panel == ReaderPanel.none &&
            (automatic.running ||
                automatic.preparing ||
                automaticController.canResume)) {
          await automaticController.discard();
          return;
        }
        if (!state.controlsVisible &&
            state.panel == ReaderPanel.none &&
            state.selection == null &&
            state.note == null) {
          await traceReaderWork(
            'reader.exit.system_back',
            () async {
              await traceReaderWork(
                'reader.exit.system.auto_pause',
                () =>
                    ref.read(automaticReadingProvider(bookId).notifier).pause(),
              );
              await traceReaderWork(
                'reader.exit.system.settings',
                () => ref
                    .read(readerSettingsProvider(bookId).notifier)
                    .pendingWrites,
              );
              await traceReaderWork(
                'reader.exit.system.position',
                () => ref
                    .read(readerSessionProvider(bookId).notifier)
                    .flushPendingPosition(),
              );
              await traceReaderWork(
                'reader.exit.system.statistics',
                () => ref.read(readingStatisticsServiceProvider).leaveVisual(),
              );
              if (!context.mounted) return;
              await prepareShelfReturn(ref);
              if (context.mounted) context.pop();
            },
            {
              'layout': settings.settings.layoutMode.name,
              'scrolling': scrolling,
              'controls': state.controlsVisible,
              'panel': state.panel.name,
            },
          );
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
          duration: MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : pageFadeDuration,
          color: theme.background,
          child: Scaffold(
            backgroundColor: Colors.transparent,
            // 键盘不压缩阅读页：正文与上下信息区都不跟着动，
            // 面板自己按键盘高度让位（ReaderSheet 处理），也不会触发整章重排
            resizeToAvoidBottomInset: false,
            body: ReaderTurnStateBoundary(
              details: {
                'layout': pageSettings.settings.layoutMode.name,
                'effect': pageSettings.settings.pageTurnEffect.name,
                'format': session?.book.format.name,
                'background':
                    [
                      'solid',
                      'newspaper',
                      'parchment',
                      'boat',
                      'landscape',
                    ].contains(theme.backgroundId)
                    ? theme.backgroundId
                    : 'custom',
                'backgroundDisposed': theme.texture?.disposed,
                'controls': state.controlsVisible,
                'panel': state.panel.name,
                'selection': state.selection != null,
                'note': state.note != null,
                'chapter': session?.chapterIndex,
                'page': session?.pageIndex,
                'settingsReady': loaded != null,
                'sourceChanged': sourceChanged,
              },
              child: Stack(
                children: [
                  CompletionPromptHost(bookId: bookId),
                  if (!ref.watch(pdfModeProvider(bookId)))
                    BookSearchPageHost(
                      key: ValueKey('search-host-$bookId'),
                      bookId: bookId,
                    ),
                  ReaderContentViewport(
                    child: Builder(
                      builder: (context) => ReaderBookmarkLayer(
                        bookId: bookId,
                        paper: theme.background,
                        backgroundImage: theme.texture?.image,
                        edgeToEdge: edgeToEdge,
                        allowPull:
                            !scrolling &&
                            !state.controlsVisible &&
                            state.selection == null &&
                            state.note == null,
                        topInset: showStatusBar
                            ? MediaQuery.paddingOf(context).top
                            : 0,
                        child: _ReadingContent(
                          state: state,
                          bookId: bookId,
                          theme: theme,
                          settings: pageSettings,
                          edgeToEdge: edgeToEdge,
                          // 设置就绪即可在加载层下准备原书网页，真实章名仍参与最终显示条件。
                          settingsReady:
                              loaded != null &&
                              (ReaderDeliveryExperiments.originalParallelOpen ||
                                  !progressTitles.isLoading),
                          titlesReady: !progressTitles.isLoading,
                        ),
                      ),
                    ),
                  ),
                  if (state.panel == ReaderPanel.none && !state.controlsVisible)
                    SearchReturnBar(
                      bookId: bookId,
                      theme: theme,
                      edgeToEdge: edgeToEdge,
                      paintMenu: scrolling,
                    ),
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
                      _TopBar(
                        visible: state.controlsVisible,
                        state: controlsState,
                        theme: theme,
                        bookId: bookId,
                      ),
                    if (!progressTitles.isLoading)
                      _BottomControls(
                        key: const ValueKey('reader-bottom-controls'),
                        visible: state.controlsVisible,
                        state: controlsState,
                        theme: theme,
                        bookId: bookId,
                      ),
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
                  if (state.panel != ReaderPanel.none &&
                      state.panel != ReaderPanel.search &&
                      !state.panelCovered)
                    Positioned(
                      left: 0,
                      right: 0,
                      top: 0,
                      bottom: readerPanelBottom(context),
                      child: GestureDetector(
                        onTap: () =>
                            ref.read(readerProvider.notifier).closePanel(),
                        child: Container(color: ReaderSheet.scrimOf(context)),
                      ),
                    ),
                  ReaderPanelViewport(
                    child: ReaderPanelMotion(
                      panel:
                          state.panel == ReaderPanel.none ||
                              state.panel == ReaderPanel.search ||
                              state.panelCovered
                          ? null
                          : state.panel,
                      delayOpening: !state.panelCovered,
                      child:
                          state.panel == ReaderPanel.none ||
                              state.panel == ReaderPanel.search ||
                              state.panelCovered
                          ? null
                          : _buildPanel(ref, state),
                    ),
                  ),
                  // 保留已有正文树，更新期间阻止继续翻页或编辑旧正文。
                  if (sourceChanged)
                    Positioned.fill(
                      child: ReaderSourceChangedPage(bookId: bookId),
                    ),
                ],
              ),
            ),
          ),
        ),
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
