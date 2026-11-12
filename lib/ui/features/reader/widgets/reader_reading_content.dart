part of '../views/reader_view.dart';

/// 正文层：顶部章节信息 + 真实分页正文 + 底部状态行。
class _ReadingContent extends ConsumerStatefulWidget {
  const _ReadingContent({
    required this.state,
    required this.bookId,
    required this.theme,
    required this.settings,
    required this.settingsReady,
    required this.noticeAboveControls,
    this.statusBar = true,
    this.navigationBar = true,
  });

  final ReaderState state;
  final String bookId;
  final ReadingTheme theme;

  /// 当前生效的阅读设置（本书设置没读出来时是全局偏好）
  final ReaderSettingsState settings;

  /// 本书设置是否已读出来
  final bool settingsReady;
  final bool noticeAboveControls;

  /// 顶部状态栏／底部导航栏当前是否显示；各自决定对应那一边要不要避让。
  final bool statusBar;
  final bool navigationBar;

  @override
  ConsumerState<_ReadingContent> createState() => _ReadingContentState();
}

class _ReadingContentState extends ConsumerState<_ReadingContent> {
  final _transitionKey = GlobalKey();
  final _displayWork = ValueNotifier(false);
  late final ReaderProgressReturn _progressReturn;
  late final Future<void> Function() _prepareJumpCover;
  late final Future<void> Function() _finishJumpCover;
  var _originalKey = GlobalKey();
  var _pageKey = GlobalKey<_PageAreaState>();
  var _scrollKey = GlobalKey<OriginalScrollAreaState>();
  var _textScrollKey = GlobalKey<SimplifiedScrollAreaState>();
  var _pdfKey = GlobalKey<PdfReaderAreaState>();
  final _spreadKey = GlobalKey<_ReaderSpreadAreaState>();
  Book? _displayBook;
  OriginalLayoutController? _displayOriginal;
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
    _prepareJumpCover = () =>
        ReaderDisplayTransition.captureForJump(_transitionKey);
    _progressReturn.prepareJumpCover = _prepareJumpCover;
    _finishJumpCover = () => ReaderDisplayTransition.finishJump(_transitionKey);
    _progressReturn.finishJumpCover = _finishJumpCover;
    _progressReturn.finishImmediateJumpCover = () =>
        ReaderDisplayTransition.finishJump(_transitionKey, immediate: true);
  }

  @override
  void dispose() {
    if (_progressReturn.prepareJumpCover == _prepareJumpCover) {
      _progressReturn.prepareJumpCover = null;
      _progressReturn.finishJumpCover = null;
      _progressReturn.finishImmediateJumpCover = null;
    }
    _displayWork.dispose();
    super.dispose();
  }

  Future<NativeReadingFrame?> _captureNative() async {
    if (!ReadingLayoutMode.originalIncluded) return null;
    if (_scrollKey.currentState != null) {
      return OriginalScrollArea.capture(_scrollKey);
    }
    if (_originalKey.currentState != null) {
      return OriginalReaderArea.capture(_originalKey);
    }
    return null;
  }

  bool _displayReady() {
    // 失败页也是准备结束，不能继续盖着加载动画隐藏真正的错误。
    final session = ref.read(readerSessionProvider(bookId));
    if (session.hasError && !session.isLoading) return true;
    final current = session.value;
    // 正文可在加载层下并行准备。揭页时进度滑块依赖的全书索引也应可用。
    if (current == null ||
        ref.read(progressTitlesProvider(bookId)).isLoading ||
        ref
            .read(pageProgressTitlesProvider((bookId, current.chapterIndex)))
            .isLoading) {
      return false;
    }
    if (ref.read(readerSessionProvider(bookId).notifier).displayTarget !=
        null) {
      return false;
    }
    if (ReadingLayoutMode.originalIncluded) {
      if (_scrollKey.currentState case final scroll?) return scroll.isReady;
      if (_originalKey.currentState != null) {
        return OriginalReaderArea.ready(_originalKey);
      }
    }
    if (_textScrollKey.currentState case final scroll?) return scroll.isReady;
    if (_pdfKey.currentState case final pdf?) return pdf.isReady;
    if (_spreadKey.currentState case final spread?) return spread.isReady;
    return _pageKey.currentState?.isReady ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final sessionAsync = ref.watch(readerSessionProvider(bookId));
    final session = sessionAsync.value;
    if (session != null) {
      // 页内信息行、原书与滚动共用这份章名，保活到当前正文完成交接。
      ref.watch(pageProgressTitlesProvider((bookId, session.chapterIndex)));
    }
    if (session != null && !identical(_displayBook, session.book)) {
      // 来源刷新仍沿用 bookId 和正文规则版本，但章节与会话已经换了。
      // 重建各显示器，避免滚动窗口继续使用旧章节列表或已释放的会话；外层保留旧截图。
      _displayBook = session.book;
      _displayOriginal = null;
      _originalKey = GlobalKey();
      _pageKey = GlobalKey<_PageAreaState>();
      _scrollKey = GlobalKey<OriginalScrollAreaState>();
      _textScrollKey = GlobalKey<SimplifiedScrollAreaState>();
      _pdfKey = GlobalKey<PdfReaderAreaState>();
      _reportedOriginalError = null;
    }
    final searchBusy = ref.watch(
      bookSearchNavigationProvider(bookId).select((s) => s.busy),
    );
    final jumpBusy = ref.watch(
      readerProgressReturnProvider(bookId).select((s) => s.busy),
    );
    return ReadingStatisticsScope(
      bookId: bookId,
      onVolumeTurn: (forward) async {
        if (_spreadKey.currentState case final spread?) {
          await spread.turn(forward);
        } else if (_pdfKey.currentState case final pdf?) {
          await pdf.volumeTurn(forward);
        } else if (_textScrollKey.currentState case final scroll?) {
          await scroll.volumeTurn(forward);
        } else if (ReadingLayoutMode.originalIncluded &&
            _scrollKey.currentState != null) {
          await _scrollKey.currentState!.volumeTurn(forward);
        } else if (ReadingLayoutMode.originalIncluded &&
            _originalKey.currentState != null) {
          await OriginalReaderArea.turn(_originalKey, forward);
        } else {
          await _pageKey.currentState?.volumeTurn(forward);
        }
      },
      ready: () =>
          settingsReady &&
          _displayReady() &&
          !ref.read(readerSessionProvider(bookId)).hasError &&
          ref.read(readerSessionProvider(bookId)).value?.currentAnchor != null,
      child: SafeArea(
        // 两个开关分别管自己那一边：显示状态栏时左侧避让状态栏和挖孔，
        // 显示导航栏时右侧避让导航栏；隐藏后那一边直接贴到屏幕边缘，
        // 挖孔挡住一点正文也接受，不在正文内部另加摄像头页边距。
        left: widget.statusBar,
        right: widget.navigationBar,
        top: widget.statusBar,
        bottom: widget.navigationBar,
        // 键盘收起的中间帧也保留导航栏留白，正文不先变高再缩回。
        maintainBottomViewPadding: true,
        child: Stack(
          children: [
            Positioned.fill(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final originalPaged =
                      settings.settings.layoutMode.isOriginal &&
                      settings.settings.pageTurnEffect != PageTurnEffect.scroll;
                  if (MediaQuery.viewInsetsOf(context).bottom == 0) {
                    _originalViewport = constraints.biggest;
                  }
                  return ReaderDisplayTransition(
                    key: _transitionKey,
                    onWorkChanged: ReaderDeliveryExperiments.originalNavigation
                        ? (busy) => _displayWork.value = busy
                        : null,
                    appearance: theme,
                    // PDF两种显示器都能截图，切换时保留旧页直到新页准备完成。
                    loadingRevision: session?.book.format == BookFormat.pdf
                        ? BookFormat.pdf
                        : settings.settings.layoutMode,
                    onReadable: ReaderPageReady.of(context),
                    onPresented: () {
                      ref
                          .read(readerSettingsProvider(bookId).notifier)
                          .releaseUnusedBackgrounds();
                      if (ReaderDeliveryExperiments.incremental) {
                        ref
                            .read(readerSessionProvider(bookId).notifier)
                            .confirmCurrentSimplifiedPage();
                      }
                    },
                    viewport: originalPaged ? _originalViewport : null,
                    reflow: originalPaged
                        ? (
                            settings.settings.fontSize,
                            settings.settings.fontFamily,
                            settings.settings.useOriginalFont,
                            settings.settings.fontWeight,
                            settings.settings.indent,
                            settings.settings.lineHeight,
                            settings.settings.paragraphGapEm,
                            settings.settings.horizontalPadding,
                            settings.settings.pageTurnEffect,
                            theme,
                            MediaQuery.textScalerOf(context),
                            ref.watch(statusInfoVisibleProvider).value,
                          )
                        : searchBusy,
                    display: (
                      settings.settings.layoutMode,
                      settings.settings.spreadEnabled,
                      settings.settings.bookEdges,
                      settings.settings.pageTurnEffect == PageTurnEffect.scroll,
                    ),
                    ready: () =>
                        !ref.read(readerSourceChangeProvider(bookId)) &&
                        settingsReady &&
                        !searchBusy &&
                        !jumpBusy &&
                        _displayReady(),
                    captureNative: _captureNative,
                    loadingBackground: theme.background,
                    child: ReaderPerformance(
                      diagnosticContext: {
                        'layout': settings.settings.layoutMode.name,
                        'effect': settings.settings.pageTurnEffect.name,
                        'format': session?.book.format.name,
                        'bookEdges': settings.settings.bookEdges,
                        'landscape': settings.settings.landscape,
                        'spreadEnabled': settings.settings.spreadEnabled,
                        'spreadActive':
                            settings.settings.spreadEnabled &&
                            settings.settings.pageTurnEffect !=
                                PageTurnEffect.scroll &&
                            MediaQuery.sizeOf(context).width >
                                MediaQuery.sizeOf(context).height,
                        'fontFamily': settings.settings.fontFamily,
                        'fontSize': settings.settings.fontSize,
                        'fontWeight': settings.settings.fontWeight,
                        'lineHeight': settings.settings.lineHeight,
                        'paragraphGapEm': settings.settings.paragraphGapEm,
                        'useOriginalFont': settings.settings.useOriginalFont,
                        'chapter': session?.chapterIndex,
                        'controls': state.controlsVisible,
                        'panel': state.panel.name,
                      },
                      label:
                          '${settings.settings.layoutMode.name}.${settings.settings.pageTurnEffect.name}',
                      child: _body(context, ref, sessionAsync, session),
                    ),
                  );
                },
              ),
            ),
            // 一次性提示（全书首尾、原书排版不可用）：两种排版模式共用一处显示
            if (state.notice != null && !widget.noticeAboveControls)
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
      ),
    );
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
      if (!annotations.hasValue && annotations.isLoading) {
        return const _PreparingState();
      }
    }

    if (session.book.format == BookFormat.pdf &&
        settings.settings.layoutMode.isOriginal) {
      return PdfReaderArea(
        key: _pdfKey,
        bookId: bookId,
        session: session,
        settings: settings,
      );
    }
    if (settings.settings.pageTurnEffect == PageTurnEffect.scroll &&
        (!settings.settings.layoutMode.isOriginal ||
            !session.book.format.supportsOriginalLayout)) {
      return SimplifiedScrollArea(
        key: _textScrollKey,
        bookId: bookId,
        session: session,
        settings: settings,
      );
    }

    if (settings.settings.spreadEnabled &&
        !settings.settings.layoutMode.isOriginal) {
      return _ReaderSpreadArea(
        key: _spreadKey,
        bookId: bookId,
        session: session,
        settings: settings,
      );
    }

    // 常量判断让发布编译移除未启用的电子书 WebView 正文；PDF 原页在上方单独处理。
    if (ReadingLayoutMode.originalIncluded &&
        settings.settings.layoutMode.isOriginal &&
        session.book.format.usesOriginalWebView) {
      final original = ref.watch(originalLayoutProvider(bookId));
      // Provider 更新时可能暂存上一份 value；已关闭的旧原书服务不能交给新显示器。
      if (original.isLoading) return const _PreparingState();
      // 原书内容打不开（源文件缺失、与章节索引对不上）：降级回简化排版，
      // 并把原因告诉用户，而不是留一个空白页（计划 3.1）
      if (original.hasError && !original.isLoading) {
        if (ref.read(readerSourceChangeProvider(bookId))) {
          return const SizedBox.expand();
        }
        if (isSourceChange(original.error)) {
          if (_reportedOriginalError != original.error) {
            _reportedOriginalError = original.error;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) {
                ref
                    .read(readerSourceChangeProvider(bookId).notifier)
                    .markChanged();
              }
            });
          }
          return const SizedBox.expand();
        }
        if (_reportedOriginalError != original.error) {
          _reportedOriginalError = original.error;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            ref
                .read(readerSessionProvider(bookId).notifier)
                .setLayoutMode(ReadingLayoutMode.simplified);
            ref.read(readerProvider.notifier).showNotice('原书内容无法读取，已用简化排版显示');
          });
        }
        if (settings.settings.pageTurnEffect == PageTurnEffect.scroll) {
          return SimplifiedScrollArea(
            bookId: bookId,
            session: session,
            settings: settings,
          );
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
      if (!identical(_displayOriginal, controller)) {
        _displayOriginal = controller;
        _originalKey = GlobalKey();
        _scrollKey = GlobalKey<OriginalScrollAreaState>();
      }
      if (settings.settings.pageTurnEffect == PageTurnEffect.scroll) {
        return OriginalScrollArea(
          key: _scrollKey,
          bookId: bookId,
          session: session,
          settings: settings,
          original: controller,
        );
      }
      return OriginalReaderArea(
        key: _originalKey,
        foregroundWork: _displayWork,
        bookId: bookId,
        session: session,
        controller: controller,
        settings: settings.settings,
        theme: settings.theme,
        onCenterTap: () =>
            ref.read(automaticReadingProvider(bookId).notifier).centerTap(),
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
