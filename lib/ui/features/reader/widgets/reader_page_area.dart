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
  final _neighborMaterials = <PreparedPage>[];
  final _presentationOwner = Object();
  ReaderSessionNotifier? _presenter;
  @override
  void initState() {
    super.initState();
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
    for (final page in _neighborMaterials) {
      page.dispose();
    }
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
          settings: settings,
          contentSize: contentSize,
          textScaler: MediaQuery.textScalerOf(context),
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

  Widget _page(ReaderSession session, ReadingSettings settings, Size pageSize) {
    final layout = session.layout;
    if (layout == null || !session.isReady) {
      // 首屏：参数已提交，等排版结果；此处保持稳定加载态，不先闪空页
      return const _PreparingState();
    }
    final resolve = ref.read(chapterContentRepositoryProvider);
    final bookId = widget.bookId;
    final version = session.book.contentVersion;

    // 书页包括顶部信息、正文及底部状态，静态页与翻页共用完整画布。
    // 正文仍按扣除信息区后的尺寸排版，选区坐标也使用相同原点。
    // 选区（原型）：只画在本章内，跨章选区不验证
    final selection = widget.state.selection;
    // 持久高亮（笔记与高亮记录）：铺在文字下面，随分页重算（S6）。
    // 第一次还没读出来时先不画这一页：等高亮到位再一起显示，
    // 不然会先看到一段没有底色的正文、隔一下底色才补上
    final annotationsAsync = ref.watch(annotationsProvider(bookId));
    final annotations = ref.watch(readerHighlightsProvider(bookId));
    if (!annotationsAsync.hasValue && annotationsAsync.isLoading) {
      return const _PreparingState();
    }
    final speech = ref.watch(listeningViewStateProvider).value;
    final unit = speech?.hasSession == true ? speech?.activeUnit : null;
    List<Rect> rectsFor(ChapterLayout source, int index) {
      // 点已有高亮选出来的选区不铺临时底色：那一段本来就有高亮底色，再叠一层
      // 看起来就像高亮被画了两遍、颜色变重（真机反馈）
      if (selection == null || widget.state.selectionFromMark) return const [];
      // 跨章选区：按章节顺序裁到这一章（首章到章末、末章从章首、中间章整章）
      return ref
          .read(readerEngineProvider)
          .selectionRects(
            source,
            index,
            selection.start,
            selection.end,
            chapterOrdinals: chapterOrdinalsOf(session.chapters),
          );
    }

    // 这一页上每条标注的矩形（只算本章里的记录，跨章选区由引擎裁到本章）
    List<({Annotation annotation, List<Rect> rects})> marksFor(
      ChapterLayout source,
      int index,
    ) {
      if (annotations.isEmpty) return const [];
      final ordinals = chapterOrdinalsOf(session.chapters);
      final engine = ref.read(readerEngineProvider);
      final result = <({Annotation annotation, List<Rect> rects})>[];
      for (final annotation in annotations) {
        if (annotation.isBookmark || annotation.color == null) continue;
        final end = annotation.end ?? annotation.start;
        final first = ordinals[annotation.start.chapterId],
            last = ordinals[end.chapterId];
        final current = ordinals[source.chapterId];
        if (first == null ||
            last == null ||
            current == null ||
            current < first ||
            current > last) {
          continue;
        }
        final rects = engine.selectionRects(
          source,
          index,
          annotation.start,
          end,
          chapterOrdinals: ordinals,
        );
        if (rects.isEmpty) continue;
        result.add((annotation: annotation, rects: rects));
      }
      return result;
    }

    List<CaretGeometry> handlesFor(ChapterLayout source, int index) {
      if (selection == null || widget.state.selectionFromMark) return const [];
      final engine = ref.read(readerEngineProvider);
      return [
        for (final end in [false, true])
          if (end != _draggedSelectionEnd)
            ?engine.caretAt(
              source,
              index,
              end ? selection.end : selection.start,
              atEnd: end,
            ),
      ];
    }

    List<PageThoughtMarker> thoughtsFor(ChapterLayout source, int index) => [
      for (final mark in marksFor(source, index))
        if (mark.annotation.body.trim().isNotEmpty &&
            ref
                    .read(readerEngineProvider)
                    .caretAt(
                      source,
                      index,
                      mark.annotation.end!,
                      atEnd: true,
                    ) !=
                null)
          PageThoughtMarker(
            id: mark.annotation.id,
            rect: thoughtMarkerRect(mark.rects.last, source.contentSize.width),
            color: readingLinkColor(widget.settings.theme),
          ),
    ];

    PageCanvas content(ChapterLayout source, int index) => PageCanvas(
      onReady: source.samePageAs(layout, index, session.pageIndex)
          ? () {
              if (!ReaderDeliveryExperiments.incremental) {
                _preparedLayout = source;
                _preparedPage = index;
                return;
              }
              final reader = ref.read(readerSessionProvider(bookId).notifier);
              final next = reader.peekNext(), previous = reader.peekPrevious();
              _prepareWindow(source, index, [
                if (next != null) content(next.layout, next.pageIndex),
                if (previous != null)
                  content(previous.layout, previous.pageIndex),
              ], current: content(source, index));
            }
          : null,
      textCache: _textCache,
      information: readerInformation(
        context,
        ref,
        session,
        settings,
        widget.settings.theme,
        session.chapters.indexWhere((c) => c.id == source.chapterId),
        source.progressOfPage(index),
        bookmarked:
            ref
                .watch(bookmarksProvider(bookId))
                .value
                ?.any(
                  (mark) =>
                      mark.locator.chapterId == source.chapterId &&
                      source.pageIndexOf(mark.locator) == index,
                ) ??
            false,
        showReturnProgress:
            source.chapterId == session.chapter.id &&
            index == session.pageIndex,
      ),
      layout: source,
      pageIndex: index,
      theme: widget.settings.theme,
      selectionRects: rectsFor(source, index),
      selectionHandles: handlesFor(source, index),
      handleColor: context.gtColors.actionPrimary,
      thoughtMarkers: thoughtsFor(source, index),
      highlights: [
        for (final mark in marksFor(source, index))
          PageHighlight(
            color: pageHighlightColorOf(mark.annotation.color),
            rects: mark.rects,
          ),
      ],
      speechRects: unit == null
          ? const []
          : speechRectsForPage(
              layout: source,
              pageIndex: index,
              from: unit.sentenceStart,
              to: unit.sentenceEnd,
            ),
      resolveResource: (path) =>
          resolve.resourceAbsolutePath(bookId, version, path),
    );
    Widget page(ChapterLayout source, int index) => content(source, index);
    final peekNext = ref
        .read(readerSessionProvider(bookId).notifier)
        .peekNext();
    final peekPrevious = ref
        .read(readerSessionProvider(bookId).notifier)
        .peekPrevious();

    final manual = PageTurnArea(
      key: _inputKey,
      inputRevision: settings,
      effect: settings.pageTurnEffect,
      onManualStart: () => unawaited(
        ref.read(automaticReadingProvider(bookId).notifier).discard(),
      ),
      onTapIntercept: (point) async {
        final auto = ref.read(automaticReadingProvider(bookId).notifier);
        if (auto.consumePauseTap()) return true;
        final ratio = point.dx / pageSize.width;
        if (auto.canResume &&
            ratio >= GtReadingTapZones.previousEdge &&
            ratio <= GtReadingTapZones.nextEdge) {
          auto.centerTap();
          return true;
        }
        await auto.discard();
        if (!mounted) return true;
        final canvas = content(layout, session.pageIndex);
        final size = context.size!;
        final origin = Offset(
          (size.width - layout.contentSize.width) / 2,
          (size.height -
                  layout.contentSize.height +
                  (canvas.information?.top ?? 0) -
                  (canvas.information?.bottom ?? 0)) /
              2,
        );
        final localPoint = point - origin;
        for (final marker in canvas.thoughtMarkers) {
          if (!marker.rect.inflate(8).contains(localPoint)) continue;
          final note = annotations.firstWhere((a) => a.id == marker.id);
          await ref
              .read(readerSessionProvider(bookId).notifier)
              .beginManualReading();
          if (!mounted) return true;
          final box = context.findRenderObject()! as RenderBox;
          await showThoughtPopover(
            context,
            body: note.body,
            theme: widget.settings.theme,
            anchor: marker.rect.shift(box.localToGlobal(origin)),
          );
          return true;
        }
        // 点到已有的高亮/笔记：直接开它的操作菜单（改颜色、编辑想法、删除），
        // 不再翻页（S6）；矩形已经是页内容盒坐标，减掉原点即可命中。
        // fromMark：只摆菜单，不画手柄与临时底色
        for (final mark in marksFor(layout, session.pageIndex)) {
          if (mark.annotation.id == searchPreviewId) continue;
          final local = point - origin;
          if (mark.rects.any((rect) => rect.inflate(2).contains(local))) {
            ref
                .read(readerProvider.notifier)
                .startSelection(
                  mark.annotation.start,
                  mark.annotation.end ?? mark.annotation.start,
                  fromMark: true,
                );
            return true;
          }
        }
        for (final fragment in layout.page(session.pageIndex)!.fragments) {
          if (!mounted) return true;
          final imageSize = fragment.imageSize;
          final path = fragment.block.resourcePath;
          if (!fragment.frameOnly &&
              imageSize != null &&
              path != null &&
              (Offset(
                        fragment.block.tableId == null
                            ? 0
                            : fragment.block.inset,
                        fragment.y,
                      ) &
                      imageSize)
                  .contains(point - origin)) {
            final file = File(canvas.resolveResource(path));
            if (await tryReaderImageGallery(
              context,
              ref,
              bookId,
              path,
              chapterId: session.chapter.id,
              blockId: fragment.block.blockId,
            )) {
              return true;
            }
            if (!mounted) return true;
            if (path.toLowerCase().endsWith('.svg')) {
              await showReaderSvg(context, SvgFileLoader(file));
            } else {
              await showReaderImage(context, FileImage(file));
            }
            return true;
          }
        }
        return false;
      },
      resolvePage: (direction) async {
        final target = await ref
            .read(readerSessionProvider(bookId).notifier)
            .prepareAdjacent(direction == PageTurnDirection.forward);
        if (!mounted || target == null) return null;
        return page(target.layout, target.pageIndex);
      },
      prepareFold: (direction) async {
        final target = await ref
            .read(readerSessionProvider(bookId).notifier)
            .prepareAdjacent(direction == PageTurnDirection.forward);
        if (!mounted) return null;
        if (target == null) return null;
        return FoldFrames.load(
          content(layout, session.pageIndex),
          content(target.layout, target.pageIndex),
          createLocalImageConfiguration(context),
          rasterCache: _rasterCache,
        );
      },
      // 翻页动画期间暂停菜单与手柄触摸，手柄外观已在书页画布中。
      traceLabel: 'simplified',
      onSettling: (direction) {
        _rasterBackward = direction == PageTurnDirection.backward;
        LayoutWorkGate.hold(_motionWorkOwner);
        if (!_pageTurning) setState(() => _pageTurning = true);
      },
      onGestureFinished: () {
        LayoutWorkGate.release(_motionWorkOwner);
        if (_pageTurning) setState(() => _pageTurning = false);
      },
      turnId: '${layout.chapterId}#${session.pageIndex}',
      currentPage: page(layout, session.pageIndex),
      nextPage: peekNext == null
          ? null
          : page(peekNext.layout, peekNext.pageIndex),
      previousPage: peekPrevious == null
          ? null
          : page(peekPrevious.layout, peekPrevious.pageIndex),
      // 有选区时点正文中间先取消选区，不切控制栏（原型交互）
      onCenterTap: () {
        final vm = ref.read(readerProvider.notifier);
        if (widget.state.selection != null) {
          vm.clearSelection();
          return;
        }
        ref.read(automaticReadingProvider(bookId).notifier).centerTap();
      },
      onTurn: (direction) async {
        final notifier = ref.read(readerSessionProvider(bookId).notifier);
        final result = direction == PageTurnDirection.forward
            ? await notifier.nextPage()
            : await notifier.previousPage();
        if (!mounted) return false;
        switch (result) {
          case PageTurnResult.moved:
            return true;
          case PageTurnResult.atBookStart:
            _showNotice('已经是第一页了');
            return false;
          case PageTurnResult.atBookEnd:
            _showNotice('已经是最后一页了');
            return false;
        }
      },
    );
    final size = pageSize;
    return AutomaticScanArea(
      bookId: bookId,
      page: (
        bookId: bookId,
        contentVersion: version,
        layout: (
          layout.options.layoutSignature,
          widget.settings.theme,
          annotations,
        ),
        page: (layout.chapterId, session.pageIndex),
      ),
      ready: () =>
          mounted &&
          widget.session.isReady &&
          !_pageTurning &&
          layout.samePageAs(
            ref.read(readerSessionProvider(bookId)).value?.layout,
            session.pageIndex,
          ) &&
          LayoutOptions(
                settings: ref
                    .read(readerSettingsProvider(bookId))
                    .requireValue
                    .settings,
                contentSize: layout.contentSize,
                textScaler: layout.options.textScaler,
              ).layoutSignature ==
              layout.options.layoutSignature,
      bounds: Offset.zero & size,
      paper: widget.settings.theme.background,
      line: widget.settings.theme.secondary,
      child: manual,
      prepare: (_) async {
        final notifier = ref.read(readerSessionProvider(bookId).notifier);
        final target = await notifier.prepareAdjacent(true);
        if (!mounted) throw StateError('阅读页已关闭');
        final targetContent = target == null
            ? null
            : await resolve.chapter(
                bookId,
                session.chapters.firstWhere(
                  (c) => c.id == target.layout.chapterId,
                ),
              );
        if (!mounted) throw StateError('阅读页已关闭');
        final frames = await ScanFrames.load(
          content(layout, session.pageIndex),
          target == null ? null : content(target.layout, target.pageIndex),
          createLocalImageConfiguration(context),
          size,
          MediaQuery.devicePixelRatioOf(context),
        );
        return ScanPreparation(
          frames,
          target == null
              ? null
              : () => notifier.commitScanPage(
                  current: layout,
                  currentPage: session.pageIndex,
                  next: target.layout,
                  nextPage: target.pageIndex,
                  content: targetContent!,
                ),
          targetPage: target == null
              ? null
              : (target.layout.chapterId, target.pageIndex),
        );
      },
    );
  }

  /// 拖动点超出正文盒子上下沿时，算出要往前/往后跳几页（0 表示在盒子内）
  int _pageOffsetFor(Offset point, Size contentSize) {
    if (point.dy < 0) {
      return -(1 + (-point.dy / contentSize.height).ceil());
    }
    if (point.dy > contentSize.height) {
      return 1 + ((point.dy - contentSize.height) / contentSize.height).floor();
    }
    return 0;
  }

  /// 长按/拖动：把页面坐标换算到正文盒子坐标，再问引擎落在哪个字上
  Future<void> _onLongPress(
    Offset localPosition,
    BoxConstraints area,
    Size contentSize,
  ) async {
    await ref.read(automaticReadingProvider(widget.bookId).notifier).discard();
    if (!mounted) return;
    final session = widget.session;
    final layout = session.layout;
    if (layout == null) return;
    final info = readerInformation(
      context,
      ref,
      session,
      widget.settings.settings,
      widget.settings.theme,
      session.chapterIndex,
      session.chapterProgress,
    );
    // 起选位置与整页画布中的正文原点一致。
    final origin = Offset(
      (area.maxWidth - contentSize.width) / 2,
      (area.maxHeight - contentSize.height + info.top - info.bottom) / 2,
    );
    final engine = ref.read(readerEngineProvider);
    final point = localPosition - origin;
    final vm = ref.read(readerProvider.notifier);
    // 还没起选，或现在这段选区是「点已有高亮」选出来的：都按新选文开始，
    // 不在旧高亮的范围上接着延伸（用户口径：改范围要重新选文字）
    if (widget.state.selection == null || widget.state.selectionFromMark) {
      final sentence = engine.sentenceRangeAtPoint(
        layout,
        session.pageIndex,
        point,
      );
      if (sentence == null) return;
      vm.startSelection(sentence.start, sentence.end);
      return;
    }
    // 拖出页面下沿/上沿：按拖出的距离整页整页地往后/往前选（原型口径）
    final beyond = _pageOffsetFor(point, contentSize);
    if (beyond != 0) {
      final target = (session.pageIndex + beyond)
          .clamp(0, math.max(0, layout.pageCount - 1))
          .toInt();
      final edge = pageEdgeLocator(
        layout: layout,
        pageIndex: target,
        atEnd: beyond > 0,
      );
      if (edge != null) vm.extendSelection(edge);
      return;
    }
    final locator = engine.locatorAtPoint(layout, session.pageIndex, point);
    if (locator == null) return;
    vm.extendSelection(locator);
  }

  void _showNotice(String message) =>
      ref.read(readerProvider.notifier).showNotice(message);
}
