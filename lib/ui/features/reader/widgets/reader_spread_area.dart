part of '../views/reader_view.dart';

typedef _SpreadPair = ({SpreadPageRef left, SpreadPageRef? right});

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
  bool _moving = false, _automaticTurn = false;
  bool? _draggedSelectionEnd;
  void _selectionDragChanged(bool? end) =>
      setState(() => _draggedSelectionEnd = end);
  Size _size = Size.zero;
  double? _stableHeight;
  late final ReaderSessionNotifier _presenter;
  final _presentationOwner = Object();
  @override
  void initState() {
    super.initState();
    _presenter = ref.read(readerSessionProvider(widget.bookId).notifier);
    _presenter.attachVisualPresenter(_presentationOwner);
  }

  bool get isReady =>
      _pair != null &&
      _materials.isNotEmpty &&
      _pair!.left.layout.samePageAs(
        widget.session.layout,
        _pair!.left.pageIndex,
        widget.session.pageIndex,
      ) &&
      _pair!.left.layout.options.layoutSignature == _viewport;
  ReaderSessionNotifier get _reader =>
      ref.read(readerSessionProvider(widget.bookId).notifier);
  Future<void> turn(bool forward) => PageTurnArea.turn(_input, forward);
  @override
  void dispose() {
    _generation++;
    _presenter.detachVisualPresenter(_presentationOwner);
    _text.dispose();
    for (final page in [..._materials, ..._targetMaterials]) {
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
  ]);
  void _prepare(SpreadPageRef left) {
    final key = (
      left.layout.page(left.pageIndex),
      left.layout.options.layoutSignature,
    );
    if (_request == key) return;
    _request = key;
    final generation = ++_generation;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        final right = await _reader.adjacentSpreadPage(left, true);
        if (!mounted || generation != _generation) return;
        final pair = (left: left, right: right);
        final pages = await _load(pair);
        if (!mounted || generation != _generation) {
          for (final p in pages) {
            p.dispose();
          }
          return;
        }
        final old = _materials;
        setState(() {
          _pair = pair;
          _materials = pages;
        });
        WidgetsBinding.instance.addPostFrameCallback((_) {
          for (final p in old) {
            p.dispose();
          }
          if (!mounted || generation != _generation) return;
          _reader.confirmSimplifiedPage(left.layout, left.pageIndex);
          _publishVisible();
          left.layout.resumeBackground();
        });
      } catch (error, stack) {
        AppErrors.report(error, stack, operation: '准备横屏双页失败');
      }
    });
  }

  void _publishVisible() {
    final pair = _pair;
    if (pair != null) {
      ref.read(visibleSpreadProvider(widget.bookId).notifier).show([
        pair.left,
        ?pair.right,
      ]);
    }
  }

  Future<_SpreadPair?> _resolve(bool forward) async {
    final pair = _pair;
    if (pair == null) return null;
    SpreadPageRef? left;
    if (forward) {
      if (pair.right == null) return null;
      left = await _reader.adjacentSpreadPage(pair.right!, true);
    } else {
      final previous = await _reader.adjacentSpreadPage(pair.left, false);
      if (previous == null) return null;
      left = await _reader.adjacentSpreadPage(previous, false) ?? previous;
    }
    if (left == null) return null;
    return (left: left, right: await _reader.adjacentSpreadPage(left, true));
  }

  ui.Image _image(
    _SpreadPair pair,
    List<PreparedPage> materials, {
    required bool current,
  }) {
    final recorder = ui.PictureRecorder();
    final ratio = MediaQuery.devicePixelRatioOf(context);
    final canvas = Canvas(recorder)..scale(ratio);
    _paintPair(canvas, _size, pair, materials, current: current);
    final picture = recorder.endRecording();
    try {
      return picture.toImageSync(
        (_size.width * ratio).ceil(),
        (_size.height * ratio).ceil(),
      );
    } finally {
      picture.dispose();
    }
  }

  void _paintPair(
    Canvas canvas,
    Size size,
    _SpreadPair pair,
    List<PreparedPage> pages, {
    required bool current,
  }) {
    final half = Size(size.width / 2, size.height);
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = widget.settings.theme.background,
    );
    pages[0].paint(
      canvas,
      half,
      appearance: _canvas(pair.left, 0, current: current),
    );
    if (pair.right != null) {
      canvas.save();
      canvas.translate(half.width, 0);
      pages[1].paint(
        canvas,
        half,
        appearance: _canvas(pair.right!, 1, current: current),
      );
      canvas.restore();
    } else {
      canvas.save();
      canvas.translate(half.width, 0);
      readerInformation(
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
            current && ref.read(currentBookmarkProvider(widget.bookId)) != null,
      ).paint(canvas, half);
      canvas.restore();
    }
    BookPaperPainter(
      widget.settings.theme.background,
      spread: true,
      edges: widget.settings.settings.bookEdges,
      decorationOnly: true,
    ).paint(canvas, size);
    if (current) {
      ref
          .read(searchMenuAppearanceProvider(widget.bookId))
          ?.paint(canvas, size);
    }
  }

  @override
  Widget build(BuildContext context) {
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
          settings: settings,
          textScaler: MediaQuery.textScalerOf(context),
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
        Widget page = GestureDetector(
          onLongPressStart: (event) => _select(event.localPosition),
          onLongPressMoveUpdate: (event) {
            if (event.offsetFromOrigin.distance > kSelectionDragSlop) {
              _select(event.localPosition, extend: true);
            }
          },
          child: PageTurnArea(
            key: _input,
            spread: true,
            inputAllowed: () => isReady,
            inputRevision: (settings, _viewport),
            currentPage: CustomPaint(
              painter: _SpreadPainter(
                (c, s) => _paintPair(c, s, pair, _materials, current: true),
              ),
            ),
            previousPage: null,
            nextPage: null,
            turnId: (
              pair.left.layout.page(pair.left.pageIndex),
              pair.left.pageIndex,
            ),
            onManualStart: () {
              if (!_automaticTurn) {
                unawaited(
                  ref
                      .read(automaticReadingProvider(widget.bookId).notifier)
                      .discard(),
                );
              }
            },
            onTapIntercept: _tap,
            onCenterTap: () => ref
                .read(automaticReadingProvider(widget.bookId).notifier)
                .centerTap(),
            resolvePage: (direction) async {
              _target = null;
              for (final p in _targetMaterials) {
                p.dispose();
              }
              _targetMaterials = [];
              final token = _generation;
              final next = await _resolve(
                direction == PageTurnDirection.forward,
              );
              if (!mounted || token != _generation || next == null) return null;
              final materials = await _load(next);
              if (!mounted || token != _generation) {
                for (final p in materials) {
                  p.dispose();
                }
                return null;
              }
              for (final p in _targetMaterials) {
                p.dispose();
              }
              _target = next;
              _targetMaterials = materials;
              return const SizedBox.expand();
            },
            prepareFold: (direction) async => _target == null
                ? null
                : FoldFrames.spread(
                    _image(pair, _materials, current: true),
                    _image(_target!, _targetMaterials, current: false),
                    _size,
                    backward: direction == PageTurnDirection.backward,
                    paper: widget.settings.theme.background,
                    edges: settings.bookEdges,
                  ),
            onSettling: (_) {
              if (mounted) setState(() => _moving = true);
            },
            onGestureFinished: () {
              if (mounted) setState(() => _moving = false);
            },
            onTurn: (direction) async {
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
              if (!_automaticTurn) await _reader.beginManualReading();
              _request = (
                next.left.layout.page(next.left.pageIndex),
                next.left.layout.options.layoutSignature,
              );
              await _reader.commitSpreadPage(pair.left, next.left);
              if (!mounted) return false;
              final old = _materials;
              setState(() {
                _pair = next;
                _materials = _targetMaterials;
                _targetMaterials = [];
                _target = null;
                _moving = false;
                _request = (
                  next.left.layout.page(next.left.pageIndex),
                  next.left.layout.options.layoutSignature,
                );
              });
              WidgetsBinding.instance.addPostFrameCallback((_) {
                for (final p in old) {
                  p.dispose();
                }
                if (mounted) {
                  _reader.confirmSimplifiedPage(
                    next.left.layout,
                    next.left.pageIndex,
                  );
                  _publishVisible();
                }
              });
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
        return _ReaderCanvas(
          height: _size.height,
          child: TimedPageTurn(
            bookId: widget.bookId,
            ready: () => isReady && !_moving,
            revision: (options.layoutSignature, widget.settings.theme),
            pages: pair.right == null ? 1 : 2,
            turn: () async {
              final before = _pair;
              _automaticTurn = true;
              try {
                await turn(true);
                return _pair != before;
              } finally {
                _automaticTurn = false;
              }
            },
            child: page,
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
