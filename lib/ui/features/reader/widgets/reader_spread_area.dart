part of '../views/reader_view.dart';

typedef _SpreadPair = ({
  SpreadPageRef left,
  SpreadPageRef? right,
  VoidCallback releaseLayouts,
});

/// 简化排版双页：两页共享会话和提交入口，每个纸面保留自己的排版与文字坐标。
class _ReaderSpreadArea extends ConsumerStatefulWidget {
  const _ReaderSpreadArea({
    super.key,
    required this.bookId,
    required this.session,
    required this.settings,
  });
  final String bookId;
  final ReaderSession session;
  final ReaderSettingsState settings;
  @override
  ConsumerState<_ReaderSpreadArea> createState() => _ReaderSpreadAreaState();
}

class _ReaderSpreadAreaState extends ConsumerState<_ReaderSpreadArea> {
  final _input = GlobalKey();
  final _text = PageTextCache();
  _SpreadPair? _pair, _target;
  List<PreparedPage> _materials = [], _targetMaterials = [];
  Object? _request;
  String? _viewport;
  int _generation = 0;
  int _targetGeneration = 0;
  bool _forward = true;
  bool? _targetForward;
  Future<bool>? _targetJob;
  _SpreadPair? _aheadOrigin;
  bool _aheadForward = true;
  Future<_SpreadPair?>? _ahead;
  final _spreadImages = <Object, ui.Image>{};
  Timer? _idlePreparation;
  bool _moving = false;
  bool _pullingBookmark = false;
  bool? _draggedSelectionEnd;
  Future<void>? _startingSelection;
  int _selectionRequest = 0;
  void _selectionDragChanged(bool? end) =>
      setState(() => _draggedSelectionEnd = end);
  Size _size = Size.zero;
  double? _stableHeight;
  late final ReaderSessionNotifier _presenter;
  final _presentationOwner = Object();
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _text.setPixelRatio(MediaQuery.devicePixelRatioOf(context));
  }

  @override
  void initState() {
    super.initState();
    _presenter = ref.read(readerSessionProvider(widget.bookId).notifier);
    _presenter.attachVisualPresenter(_presentationOwner);
    ReaderTurnStateDiagnostics.attach(
      this,
      'simplifiedSpread',
      _turnState,
      observeStalls: true,
    );
  }

  Map<String, Object?> _turnState() {
    final left = _pair?.left;
    return {
      'chapter': widget.session.chapterIndex,
      'page': widget.session.pageIndex,
      'displayedPage': left?.pageIndex,
      'pageMatches': _focusOf(_pair) != null,
      'viewportMatches': left?.layout.options.layoutSignature == _viewport,
      'materialsReady': _materials.isNotEmpty,
      'inputAllowed': isReady,
      'moving': _moving,
      'generation': _generation,
    };
  }

  Future<T> _traceSpreadStep<T>(String stage, Future<T> Function() action) =>
      ReaderTurnStateDiagnostics.step(
        stage,
        action,
        observeStalls: true,
        owner: this,
      );

  SpreadPageRef? _focusOf(_SpreadPair? pair) {
    if (pair == null) return null;
    for (final page in [pair.left, ?pair.right]) {
      if (page.layout.samePageAs(
        widget.session.layout,
        page.pageIndex,
        widget.session.pageIndex,
      )) {
        return page;
      }
    }
    return null;
  }

  bool get isReady =>
      _focusOf(_pair) != null &&
      _materials.isNotEmpty &&
      _pair!.left.layout.options.layoutSignature == _viewport;
  ReaderSessionNotifier get _reader =>
      ref.read(readerSessionProvider(widget.bookId).notifier);
  Future<void> turn(bool forward) => PageTurnArea.turn(_input, forward);
  @override
  void dispose() {
    ReaderTurnStateDiagnostics.detach(this);
    _generation++;
    _idlePreparation?.cancel();
    for (final image in _spreadImages.values) {
      image.dispose();
    }
    _spreadImages.clear();
    _presenter.detachVisualPresenter(_presentationOwner);
    _text.dispose();
    _pair?.releaseLayouts();
    _discardAhead();
    _clearTarget();
    for (final page in _materials) {
      page.dispose();
    }
    super.dispose();
  }

  Future<List<PreparedPage>> _load(_SpreadPair pair) => Future.wait([
    PreparedPage.load(
      _canvas(pair.left, 0, current: false),
      createLocalImageConfiguration(context),
    ),
    if (pair.right != null)
      PreparedPage.load(
        _canvas(pair.right!, 1, current: false),
        createLocalImageConfiguration(context),
      ),
  ], cleanUp: (page) => page.dispose());

  void _clearTarget() {
    _targetGeneration++;
    _targetJob = null;
    _targetForward = null;
    _target?.releaseLayouts();
    _target = null;
    for (final page in _targetMaterials) {
      page.dispose();
    }
    _targetMaterials = [];
  }

  Future<bool> _loadTarget(bool forward, int token) async {
    final next = await _traceSpreadStep('spread.resolve-page', () async {
      final ready = await _takeAhead(forward);
      if (ready != null || !mounted || token != _targetGeneration) return ready;
      return _resolve(forward);
    });
    if (next == null) return false;
    var adopted = false;
    try {
      if (!mounted || token != _targetGeneration) return false;
      final materials = await _traceSpreadStep(
        'spread.prepare-pages',
        () => _load(next),
      );
      if (!mounted || token != _targetGeneration) {
        for (final page in materials) {
          page.dispose();
        }
        return false;
      }
      _target = next;
      _targetMaterials = materials;
      adopted = true;
      return true;
    } finally {
      if (!adopted) next.releaseLayouts();
    }
  }

  Future<_SpreadPair> _pairFrom(SpreadPageRef target) async {
    final pages = await _reader.pagesAround(target);
    final left = pages.left;
    final right = pages.right;
    final leftTask = left.layout.task;
    final releaseLeft = leftTask?.retainForDisplay();
    try {
      final rightTask = right?.layout.task;
      // 跨章时右页有自己的排版任务，下一次前翻会从它继续查页。
      final releaseRight = identical(leftTask, rightTask)
          ? null
          : rightTask?.retainForDisplay();
      return (
        left: left,
        right: right,
        releaseLayouts: () {
          releaseLeft?.call();
          releaseRight?.call();
        },
      );
    } catch (_) {
      releaseLeft?.call();
      rethrow;
    }
  }

  void _prepare(SpreadPageRef focus) {
    final key = (
      focus.layout.page(focus.pageIndex),
      focus.layout.options.layoutSignature,
      widget.session.spreadTarget,
    );
    if (_request == key) return;
    _request = key;
    _discardAhead();
    _clearTarget();
    final generation = ++_generation;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || generation != _generation) return;
      _SpreadPair? prepared;
      try {
        if (_focusOf(_pair) != null &&
            _pair!.left.layout.options.layoutSignature == _viewport) {
          _reader.confirmSimplifiedPage(focus.layout, focus.pageIndex);
          _publishVisible();
          _scheduleSpreadPreparation();
          return;
        }
        final pair = prepared = await _pairFrom(focus);
        if (!mounted || generation != _generation) return;
        final pages = await _load(pair);
        if (!mounted || generation != _generation) {
          for (final p in pages) {
            p.dispose();
          }
          return;
        }
        final old = _materials;
        final oldPair = _pair;
        setState(() {
          _pair = pair;
          _materials = pages;
        });
        prepared = null;
        oldPair?.releaseLayouts();
        WidgetsBinding.instance.addPostFrameCallback((_) {
          for (final p in old) {
            p.dispose();
          }
          if (!mounted || generation != _generation) return;
          _reader.confirmSimplifiedPage(focus.layout, focus.pageIndex);
          _publishVisible();
          focus.layout.resumeBackground();
          _scheduleSpreadPreparation();
        });
      } on LayoutCancelled {
        if (mounted && generation == _generation) {
          setState(() => _request = null);
        }
      } catch (error, stack) {
        AppErrors.report(error, stack, operation: '准备横屏双页失败');
      } finally {
        prepared?.releaseLayouts();
      }
    });
  }

  void _publishVisible() {
    final pair = _pair;
    if (pair != null) {
      _reader.rememberShownSpread((left: pair.left, right: pair.right));
      ref.read(visibleSpreadProvider(widget.bookId).notifier).show([
        pair.left,
        ?pair.right,
      ]);
    }
  }

  Future<_SpreadPair?> _resolve(bool forward, {_SpreadPair? from}) async {
    final pair = from ?? _pair;
    if (pair == null) return null;
    final edge = forward ? pair.right ?? pair.left : pair.left;
    final adjacent = await _reader.adjacentSpreadPage(edge, forward);
    return adjacent == null ? null : _pairFrom(adjacent);
  }

  ui.Image _image(
    _SpreadPair pair,
    List<PreparedPage> materials, {
    required bool current,
  }) {
    final key = _spreadImageKey(pair, materials, current: current);
    final cached = _spreadImages[key];
    if (cached != null) return cached.clone();
    final picture = _recordPair(pair, materials, current: current);
    final ratio = MediaQuery.devicePixelRatioOf(context);
    try {
      return picture.toImageSync(
        (_size.width * ratio).ceil(),
        (_size.height * ratio).ceil(),
      );
    } finally {
      picture.dispose();
    }
  }

  ui.Picture _recordPair(
    _SpreadPair pair,
    List<PreparedPage> materials, {
    required bool current,
  }) {
    final recorder = ui.PictureRecorder();
    final ratio = MediaQuery.devicePixelRatioOf(context);
    final canvas = Canvas(recorder)..scale(ratio);
    _paintPair(canvas, _size, pair, materials, current: current);
    return recorder.endRecording();
  }

  void _presentPair(_SpreadPair next, List<PreparedPage> materials) {
    _targetGeneration++;
    _targetForward = null;
    _targetJob = null;
    final old = _materials;
    final oldPair = _pair;
    setState(() {
      _pair = next;
      _materials = materials;
      _moving = false;
      _request = (
        next.left.layout.page(next.left.pageIndex),
        next.left.layout.options.layoutSignature,
        null,
      );
    });
    oldPair?.releaseLayouts();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final page in old) {
        page.dispose();
      }
      if (!mounted || _pair != next) return;
      _reader.confirmSimplifiedPage(next.left.layout, next.left.pageIndex);
      _publishVisible();
      _scheduleSpreadPreparation();
      ReaderTurnStateDiagnostics.record('spread.page-presented', {
        'page': next.left.pageIndex,
        'generation': _generation,
      });
    });
  }

  void _paintPair(
    Canvas canvas,
    Size size,
    _SpreadPair pair,
    List<PreparedPage> pages, {
    required bool current,
  }) {
    final half = Size(size.width / 2, size.height);
    paintReadingBackground(
      canvas,
      size,
      widget.settings.theme.background,
      widget.settings.theme.texture?.image,
    );
    pages[0].paint(
      canvas,
      half,
      appearance: _canvas(pair.left, 0, current: current, spread: pair),
      paintBackground: false,
    );
    if (pair.right != null) {
      canvas.save();
      canvas.translate(half.width, 0);
      pages[1].paint(
        canvas,
        half,
        appearance: _canvas(pair.right!, 1, current: current, spread: pair),
        paintBackground: false,
      );
      canvas.restore();
    } else {
      canvas.save();
      canvas.translate(half.width, 0);
      pages.first.paintChapterPaper(canvas, half);
      final info = readerInformation(
        context,
        ref,
        widget.session,
        widget.settings.settings,
        widget.settings.theme,
        widget.session.chapterIndex,
        widget.session.chapterProgress,
        spreadSide: 1,
        showReturnProgress: false,
        bookmarked:
            current &&
            !_pullingBookmark &&
            ref.read(currentBookmarkProvider(widget.bookId)) != null,
      );
      final color = pages.first.page.cssBackground == null
          ? info.color
          : pages.first.paperInformationColor(widget.settings.theme.secondary);
      info.withColor(color).paint(canvas, half);
      canvas.restore();
    }
    if (widget.settings.settings.bookEdges) {
      paintSpreadEdges(
        canvas,
        size,
        widget.settings.theme.background,
        widget.settings.theme.texture?.image,
        leftChapterPaper:
            pages.first.page.cssBackground != null ||
            pages.first.page.hasBleedingArtwork,
        rightChapterPaper: pair.right == null
            ? pages.first.page.cssBackground != null
            : (pages[1].page.cssBackground != null ||
                  pages[1].page.hasBleedingArtwork),
      );
    }
    if (current) {
      ref
          .read(searchMenuAppearanceProvider(widget.bookId))
          ?.paint(canvas, size);
    }
  }

  @override
  Widget build(BuildContext context) {
    // 双列正文持有可见页记录，稍后打开听书面板也能直接拿到已上屏的左页。
    ref.watch(visibleSpreadProvider(widget.bookId).notifier);
    _pullingBookmark = BookmarkPullScope.activeOf(context);
    ref.watch(annotationsProvider(widget.bookId));
    ref.watch(readerHighlightsProvider(widget.bookId));
    ref.watch(bookmarksProvider(widget.bookId));
    ref.watch(listeningViewStateProvider);
    final state = ref.watch(readerProvider);
    if (isReady && _reader.annotationTarget != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && isReady) _reader.completeAnnotationLanding();
      });
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        _size = constraints.biggest;
        if (MediaQuery.viewInsetsOf(context).bottom == 0) {
          _stableHeight = _size.height;
        }
        _size = Size(_size.width, _stableHeight ?? _size.height);
        final settings = widget.settings.settings;
        final info = readerInformation(
          context,
          ref,
          widget.session,
          settings,
          widget.settings.theme,
          widget.session.chapterIndex,
          widget.session.chapterProgress,
        );
        final options = LayoutOptions(
          cssDark: widget.settings.theme.isNight,
          paperBottomInset: info.bottom + ReadingLimits.verticalPadding,
          paperInset: Offset(
            settings.horizontalPadding + bookSpineWidth,
            info.top + ReadingLimits.verticalPadding,
          ),
          pageInk: (
            primary: widget.settings.theme.primary,
            secondary: widget.settings.theme.secondary,
          ),
          settings: settings,
          textScaler: MediaQuery.textScalerOf(context),
          // 只有 TXT 补章题和短横线；EPUB／MOBI／AZW3 按原书内容与样式排。
          insertChapterTitle: widget.session.book.format == BookFormat.txt,
          spreadDocumentChapters:
              widget.session.book.format.usesOriginalWebView,
          contentSize: Size(
            math.max(
              1,
              _size.width / 2 -
                  2 * (settings.horizontalPadding + bookSpineWidth),
            ),
            math.max(
              1,
              _size.height -
                  info.top -
                  info.bottom -
                  2 * ReadingLimits.verticalPadding,
            ),
          ),
        );
        if (_viewport != options.layoutSignature) {
          _viewport = options.layoutSignature;
          if (readerTurnStateDiagnosticsEnabled) {
            ReaderTurnStateDiagnostics.record('spread.viewport', {
              'width': options.contentWidth,
              'height': options.contentHeight,
            });
          }
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _reader.applyViewport(options);
          });
        }
        if (widget.session.isReady &&
            widget.session.layout!.options.layoutSignature == _viewport &&
            ref.read(annotationsProvider(widget.bookId)).hasValue) {
          _prepare((
            layout: widget.session.layout!,
            pageIndex: widget.session.pageIndex,
          ));
        }
        final pair = _pair;
        if (pair == null) return const SizedBox.expand();
        final pages = _materials;
        final effect = settings.pageTurnEffect;
        Widget page = GestureDetector(
          onLongPressStart: (event) {
            _startingSelection = _select(event.localPosition);
          },
          onLongPressMoveUpdate: (event) {
            if (event.offsetFromOrigin.distance > kSelectionDragSlop) {
              _select(event.localPosition, extend: true);
            }
          },
          child: PageTurnArea(
            deferBookFontRefresh: true,
            key: _input,
            spread: effect == PageTurnEffect.curl,
            effect: effect,
            slideImages: true,
            inputAllowed: () => isReady,
            inputRevision: (settings, _viewport),
            currentPage: CustomPaint(
              painter: _SpreadPainter(
                (c, s) => _paintPair(c, s, pair, pages, current: true),
              ),
            ),
            previousPage: null,
            nextPage: null,
            turnId: (
              pair.left.layout.page(pair.left.pageIndex),
              pair.left.pageIndex,
            ),
            onManualStart: () => unawaited(
              ref
                  .read(automaticReadingProvider(widget.bookId).notifier)
                  .discard(),
            ),
            onTapIntercept: _tap,
            onCenterTap: () => ref
                .read(automaticReadingProvider(widget.bookId).notifier)
                .centerTap(),
            resolvePage: (direction) async => await _prepareTarget(direction)
                ? const SizedBox.expand()
                : null,
            prepareFold: (direction) async {
              final target = _target;
              if (target == null) return null;
              final before = _image(pair, _materials, current: true);
              final after = _image(target, _targetMaterials, current: false);
              final backward = direction == PageTurnDirection.backward;
              final paper = widget.settings.theme.background;
              return effect == PageTurnEffect.curl
                  ? FoldFrames.spread(
                      before,
                      after,
                      _size,
                      backward: backward,
                      paper: paper,
                      footerTarget: target.right ?? target.left,
                      edges: settings.bookEdges,
                    )
                  : FoldFrames.images(
                      before,
                      after,
                      _size,
                      backward: backward,
                      paper: paper,
                      footerTarget: target.right ?? target.left,
                    );
            },
            onSettling: (direction) {
              if (mounted) setState(() => _moving = true);
              if (effect == PageTurnEffect.curl) _prepareAhead(direction);
            },
            onGestureFinished: () {
              if (!mounted) return;
              _discardAhead();
              _clearTarget();
              setState(() => _moving = false);
              _scheduleSpreadPreparation();
            },
            onTurn: (direction) async {
              // 无动画时翻页控件直接提交，仍须先准备好目标的两列。
              if (effect == PageTurnEffect.none) {
                await _prepareTarget(direction);
                if (!mounted || !isReady) return false;
              }
              final next = _target;
              if (next == null) {
                ref
                    .read(readerProvider.notifier)
                    .showNotice(
                      direction == PageTurnDirection.forward
                          ? '已经是最后一页了'
                          : '已经是第一页了',
                    );
                return false;
              }
              final origin = _focusOf(pair);
              if (origin == null) return false;
              await _traceSpreadStep(
                'spread.manual-reading',
                _reader.beginManualReading,
              );
              if (!mounted || _target != next || _pair != pair) return false;
              _request = (
                next.left.layout.page(next.left.pageIndex),
                next.left.layout.options.layoutSignature,
                null,
              );
              await _traceSpreadStep(
                'spread.commit-page',
                () => _reader.commitSpreadPage(origin, next.left),
              );
              if (!mounted || _target != next) return false;
              final materials = _targetMaterials;
              _targetMaterials = [];
              _target = null;
              _presentPair(next, materials);
              return true;
            },
          ),
        );
        page = Stack(
          fit: StackFit.expand,
          children: [
            page,
            if (state.selection != null) ..._selectionLayers(pair, state),
          ],
        );
        if (readerUsesDesktopPanels) {
          final markers = <int, List<PageThoughtMarker>>{};
          page = ReaderLinkCursor(
            isLink: (point) {
              if (!isReady ||
                  _moving ||
                  state.controlsVisible ||
                  state.selection != null) {
                return false;
              }
              final hit = _hit(point);
              if (hit == null) return false;
              final (target, side) = hit;
              final local = point - _origin(target, side);
              return markers
                      .putIfAbsent(
                        side,
                        () =>
                            _canvas(target, side, current: true).thoughtMarkers,
                      )
                      .any(
                        (marker) => marker.rect.inflate(8).contains(local),
                      ) ||
                  readerPageLinkAt(target.layout, target.pageIndex, local);
            },
            child: page,
          );
        }
        page = ReaderLinkPress(
          bookId: widget.bookId,
          hit: (point) {
            if (!isReady ||
                _moving ||
                state.controlsVisible ||
                state.selection != null) {
              return null;
            }
            final hit = _hit(point);
            if (hit == null) return null;
            return readerLinkNearPoint(
              hit.$1.layout,
              hit.$1.pageIndex,
              point - _origin(hit.$1, hit.$2),
            )?.link;
          },
          child: page,
        );
        final numbered = pair.right ?? pair.left;
        return _ReaderCanvas(
          height: _size.height,
          // 整组只在两页都扫完后提交，手动翻页仍交给 PageTurnArea。
          child: BookPagePaper(
            session: widget.session,
            layout: numbered.layout,
            page: numbered.pageIndex,
            options: options,
            info: info,
            ready: isReady,
            enabled: info.visible && ref.watch(showBookPagesProvider),
            child: AutomaticScanArea(
              bookId: widget.bookId,
              page: (
                bookId: widget.bookId,
                contentVersion: widget.session.book.contentVersion,
                layout: (options.layoutSignature, widget.settings.theme),
                page: (pair.left.layout.chapterId, pair.left.pageIndex),
              ),
              ready: () => isReady && !_moving,
              bounds:
                  Offset.zero &
                  (pair.right == null
                      ? Size(_size.width / 2, _size.height)
                      : _size),
              columns: pair.right == null ? 1 : 2,
              secondsPerColumn: !widget.settings.desktopColumns,
              paper: widget.settings.theme.background,
              line: widget.settings.theme.secondary,
              prepare: (_) => _prepareScan(pair),
              child: page,
            ),
          ),
        );
      },
    );
  }
}

class _SpreadPainter extends CustomPainter {
  _SpreadPainter(this.draw);
  final void Function(Canvas, Size) draw;
  @override
  void paint(Canvas canvas, Size size) => draw(canvas, size);
  @override
  bool shouldRepaint(_SpreadPainter old) => true;
}
