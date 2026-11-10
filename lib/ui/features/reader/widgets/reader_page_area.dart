part of '../views/reader_view.dart';

/// 长按后拖多远才算「要延伸选区」：手指抖动不算
const double kSelectionDragSlop = 10;

/// 正文排版区：把可用尺寸与排版设置交给会话，然后画当前页。
class _PageArea extends ConsumerStatefulWidget {
  const _PageArea({
    super.key,
    required this.state,
    required this.bookId,
    required this.session,
    required this.settings,
  });

  final ReaderState state;
  final String bookId;
  final ReaderSession session;
  final ReaderSettingsState settings;

  @override
  ConsumerState<_PageArea> createState() => _PageAreaState();
}

class _PageAreaState extends ConsumerState<_PageArea> {
  final _inputKey = GlobalKey();
  final _textCache = PageTextCache();
  final _rasterCache = PageRasterCache();
  bool _rasterBackward = false;
  ChapterLayout? _preparedLayout;
  int? _preparedPage;
  final _pointerWorkOwner = Object(), _motionWorkOwner = Object();
  Object? _windowKey;
  Timer? _textPreparationTimer;
  final _pageMaterials = PreparedPageCache();
  PreparedPage? _currentMaterial;
  final _materialOwner = Object();
  late final ChapterContentRepository _materialRepository;
  final _presentationOwner = Object();
  ReaderSessionNotifier? _presenter;
  @override
  void initState() {
    super.initState();
    _materialRepository = ref.read(chapterContentRepositoryProvider);
    if (ReaderDeliveryExperiments.incremental) {
      final presenter = ref.read(readerSessionProvider(widget.bookId).notifier);
      presenter.attachVisualPresenter(_presentationOwner);
      _presenter = presenter;
    }
  }

  bool get isReady =>
      widget.session.isReady &&
      (_preparedLayout?.samePageAs(
            widget.session.layout,
            _preparedPage ?? -1,
          ) ??
          false) &&
      _preparedPage == widget.session.pageIndex;

  @override
  void dispose() {
    _presenter?.detachVisualPresenter(_presentationOwner);
    _textPreparationTimer?.cancel();
    LayoutWorkGate.release(_pointerWorkOwner);
    LayoutWorkGate.release(_motionWorkOwner);
    _pageMaterials.dispose();
    _currentMaterial?.dispose();
    unawaited(
      _materialRepository.retainReadingChapters(
        widget.bookId,
        _materialOwner,
        const [],
      ),
    );
    _textCache.dispose();
    _rasterCache.dispose();
    super.dispose();
  }

  Future<void> volumeTurn(bool forward) async {
    await ref.read(automaticReadingProvider(widget.bookId).notifier).discard();
    await ref
        .read(readerSessionProvider(widget.bookId).notifier)
        .beginManualReading();
    if (mounted) await PageTurnArea.turn(_inputKey, forward);
  }

  /// 上一次提交给引擎的参数签名，用于判断是否会触发重排
  String? _submitted;

  /// 翻页期间暂停菜单与静止手柄的触摸；手柄外观始终随书页移动。
  bool _pageTurning = false;
  bool? _draggedSelectionEnd;

  /// 键盘没弹出时的正文区高度。
  ///
  /// 键盘弹出时系统栏与窗口一起变，正文区高度会跟着变（实测 721 → 764），
  /// 信息区与正文都会被顶动。这里记下没有键盘时的高度，键盘期间固定用它。
  double? _stableHeight;

  @override
  void didUpdateWidget(_PageArea oldWidget) {
    super.didUpdateWidget(oldWidget);
    final effect = widget.settings.settings.pageTurnEffect;
    if (effect != PageTurnEffect.curl && effect != PageTurnEffect.cover) {
      _rasterCache.clear();
    }
    // 原书读取失败回退时，尺寸可能没变，但分页结果已经被切换清掉。
    if (oldWidget.session.layout != null && widget.session.layout == null) {
      _submitted = null;
    }
    // 页码/章节变了说明动画已经提交、新页上屏：可以把手柄画出来了
    if (oldWidget.session.pageIndex != widget.session.pageIndex ||
        oldWidget.session.chapterIndex != widget.session.chapterIndex) {
      // 成功提交不经过取消手势回调，也必须释放这次动画的后台暂停标记。
      if (_pageTurning) LayoutWorkGate.release(_motionWorkOwner);
      _pageTurning = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final notifier = ref.read(readerSessionProvider(widget.bookId).notifier);
    if (session.isReady && notifier.annotationTarget != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) notifier.completeAnnotationLanding();
      });
    }
    final settings = widget.settings.settings;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = math.min(
          constraints.maxWidth,
          settings.landscape ? constraints.maxWidth : GtSize.readingMaxWidth,
        );
        // 信息与正文同属一页，分页高度仍扣除信息区与原有留白。
        final info = readerInformation(
          context,
          ref,
          session,
          settings,
          widget.settings.theme,
          session.chapterIndex,
          session.chapterProgress,
        );
        // 键盘弹出期间固定用「没有键盘」时的高度：分页参数与绘制原点都不动，
        // 正文和上下信息区就不会被顶上去（键盘占住的那块在面板下面，看不见）
        final keyboard = MediaQuery.viewInsetsOf(context).bottom;
        if (keyboard == 0) _stableHeight = constraints.maxHeight;
        final layoutHeight = _stableHeight ?? constraints.maxHeight;
        final contentSize = Size(
          math.max(
            0,
            width -
                (settings.horizontalPadding +
                        (settings.bookEdges ? bookEdgeWidth : 0)) *
                    2,
          ),
          math.max(
            0,
            layoutHeight -
                info.top -
                info.bottom -
                ReadingLimits.verticalPadding * 2,
          ),
        );
        final options = LayoutOptions(
          cssDark: widget.settings.theme.isNight,
          settings: settings,
          contentSize: contentSize,
          textScaler: MediaQuery.textScalerOf(context),
          // 只有 TXT 补章题和短横线；EPUB／MOBI／AZW3 按原书内容与样式排。
          insertChapterTitle: session.book.format == BookFormat.txt,
        );
        _submitIfChanged(options);
        return _ReaderCanvas(
          height: layoutHeight,
          child: Listener(
            onPointerDown: (_) => LayoutWorkGate.hold(_pointerWorkOwner),
            onPointerUp: (_) => LayoutWorkGate.release(_pointerWorkOwner),
            onPointerCancel: (_) => LayoutWorkGate.release(_pointerWorkOwner),
            child: Stack(
              children: [
                GestureDetector(
                  // 长按起选、拖动延伸（原型级选区，实现计划 S15）
                  behavior: HitTestBehavior.translucent,
                  onLongPressStart: (details) => _onLongPress(
                    details.localPosition,
                    constraints,
                    options.contentSize,
                  ),
                  onLongPressMoveUpdate: (details) {
                    // 长按时手指总有一点抖动：没超过阈值就不动选区，
                    // 否则刚选中的句子会被截断到手指那一点（真机反馈过）
                    if (details.offsetFromOrigin.distance <
                        kSelectionDragSlop) {
                      return;
                    }
                    _onLongPress(
                      details.localPosition,
                      constraints,
                      options.contentSize,
                    );
                  },
                  onLongPressEnd: (_) {},
                  child: _page(
                    session,
                    settings,
                    Size(constraints.maxWidth, layoutHeight),
                  ),
                ),
                // 选区在的时候正文只收拖动（点按先收选区）：拖手柄不会顺手翻页，
                // 点空白处收起选区，拖动照旧翻页——跨页选区的另一头靠它看
                if (widget.state.selection != null)
                  Positioned.fill(
                    child: SelectionGestureShield(
                      onDismiss: () {
                        ref.read(readerProvider.notifier).clearSelection();
                      },
                    ),
                  ),
                // 起止手柄：拖着改选区两端（实现计划 S1b）；
                // 拖出左右页沿停 1 秒翻页——整段选区只有一对手柄，够另一头靠它
                // 必须铺满整页：手柄按页面坐标定位，缩成 0 就会既画不出也点不到。
                // 点已有高亮选出来的选区不画手柄：那段文字已经有底色，改范围只能
                // 删掉再重选（用户口径）
                if (widget.state.selection != null &&
                    !widget.state.selectionFromMark &&
                    !_pageTurning &&
                    session.layout != null &&
                    session.isReady)
                  Positioned.fill(
                    child: SelectionHandles(
                      paintIdleHandles: false,
                      onDragChanged: (end) =>
                          setState(() => _draggedSelectionEnd = end),
                      bookId: widget.bookId,
                      state: widget.state,
                      layout: session.layout!,
                      pageIndex: session.pageIndex,
                      origin: Offset(
                        (constraints.maxWidth - options.contentSize.width) / 2,
                        (constraints.maxHeight -
                                options.contentSize.height +
                                info.top -
                                info.bottom) /
                            2,
                      ),
                      theme: widget.settings.theme,
                    ),
                  ),
                // 选中文字后的操作菜单：贴着选区摆（S3）；翻页动画期间一起藏起来
                if (widget.state.selection != null &&
                    !_pageTurning &&
                    session.layout != null &&
                    session.isReady)
                  Positioned.fill(
                    child: SelectionActions(
                      bookId: widget.bookId,
                      state: widget.state,
                      rects: ref
                          .read(readerEngineProvider)
                          .selectionRects(
                            session.layout!,
                            session.pageIndex,
                            widget.state.selection!.start,
                            widget.state.selection!.end,
                            chapterOrdinals: chapterOrdinalsOf(
                              session.chapters,
                            ),
                          ),
                      origin: Offset(
                        (constraints.maxWidth - options.contentSize.width) / 2,
                        (constraints.maxHeight -
                                options.contentSize.height +
                                info.top -
                                info.bottom) /
                            2,
                      ),
                      pageSize: Size(constraints.maxWidth, layoutHeight),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 参数或尺寸变化时在帧后重排：不在 build 期间改状态（设计文档 4.2）
  void _submitIfChanged(LayoutOptions options) {
    if (_submitted == options.layoutSignature) return;
    _submitted = options.layoutSignature;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref
          .read(readerSessionProvider(widget.bookId).notifier)
          .applyViewport(options);
    });
  }

  void _setPageTurning(bool turning) {
    if (_pageTurning != turning) setState(() => _pageTurning = turning);
  }
}
