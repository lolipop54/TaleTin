part of 'pdf_reader_area.dart';

class _PdfScroll extends ConsumerStatefulWidget {
  const _PdfScroll({
    super.key,
    required this.parent,
    required this.book,
    required this.fixedView,
  });
  final PdfReaderArea parent;
  final PdfBookController book;
  final bool fixedView;
  @override
  ConsumerState<_PdfScroll> createState() => _PdfScrollState();
}

/// 页高由PDF元数据一次确定，位图按可见范围准备。未准备好的边界阻止继续滚动，
/// 准备完成后恢复可滚动范围，避免快速拖动时露出空白页。
class _PdfScrollState extends ConsumerState<_PdfScroll>
    with SingleTickerProviderStateMixin {
  final _images = <int, ui.Image>{};
  final _pending = <int, Future<void>>{};
  final _controller = ScrollController();
  List<double> _offsets = [0];
  late final _ticker = createTicker(_tick);
  late final _automatic = ref.read(
    automaticReadingProvider(parent.bookId).notifier,
  );
  late final AutomaticScrollBackend _backend;
  final _clock = FrameScrollDistance();
  Timer? _saving;
  double _width = 0, _height = 0, _speed = 24;
  int _pixels = 1000, _version = 0;
  Object? _requested;
  bool _ready = false, _jumping = false;
  Object? _error;
  ({double scale, double pixels, double x})? _zoomTarget;
  double _listScale = 1, _listX = 0;
  bool _loadingZoom = false;
  bool get ready => _ready && _controller.hasClients && _error == null;
  bool get _canScroll => ready && !_jumping && !_loadingZoom && view.canTurn;
  PdfReaderArea get parent => widget.parent;
  ReaderSessionNotifier get session =>
      ref.read(readerSessionProvider(parent.bookId).notifier);
  PdfViewport get view => ref.read(pdfViewportProvider(parent.bookId));

  @override
  void initState() {
    super.initState();
    _listScale = view.scale;
    _listX = view.offset.dx;
    view.offset = Offset(_listX, 0);
    _controller.addListener(_moved);
    _backend = AutomaticScrollBackend(
      ready: () => _canScroll,
      start: (speed) async {
        _speed = speed;
        _clock.reset();
        _ticker.start();
      },
      stop: () async {
        _ticker.stop();
        _clock.reset();
        await _report();
      },
      speed: (speed) => _speed = speed,
    );
    _automatic.attach(_backend);
  }

  int _indexAt(double offset, {double? scale}) =>
      _pdfPageAt(_offsets, offset / (scale ?? _listScale));

  Future<void> _prepare(int index) {
    if (index < 0 ||
        index >= widget.book.chapters.length ||
        _images.containsKey(index)) {
      return Future.value();
    }
    return _pending.putIfAbsent(
      index,
      () =>
          () async {
            final image = await _pdfBitmap(widget.book, index, _pixels);
            if (!mounted) {
              image.dispose();
              return;
            }
            setState(() => _images[index] = image);
          }().whenComplete(() {
            _pending.remove(index);
          }),
    );
  }

  void _warm(int index) {
    final offset = _controller.hasClients
        ? _controller.offset
        : _offsets[index] * _listScale;
    final last = math.max(index + 2, _indexAt(offset + _height) + 1);
    for (var i = index - 1; i <= last; i++) {
      unawaited(
        _prepare(i).catchError((Object error, StackTrace stack) {
          if (mounted) {
            _automatic.finish('PDF页面无法读取');
            session.reportPositionFailure(error, stack);
          }
        }),
      );
    }
    for (final i
        in _images.keys.where((i) => i < index - 2 || i > last + 1).toList()) {
      final old = _images.remove(i)!;
      WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
    }
  }

  Future<void> _prepareViewport(double offset) async {
    final first = _indexAt(offset);
    final last = _indexAt(offset + _height);
    await Future.wait([
      for (var i = first - 1; i <= last + 1; i++) _prepare(i),
    ]);
  }

  void _moved() {
    if (!_canScroll) return;
    _warm(_indexAt(_controller.offset));
    _scheduleReport();
  }

  void _scheduleReport() {
    _saving?.cancel();
    _saving = Timer(
      const Duration(milliseconds: 150),
      () => unawaited(_report()),
    );
  }

  Future<void> _report() async {
    if (!_canScroll) return;
    final pixels = _controller.offset;
    final offset = pixels / _listScale;
    final index = _indexAt(pixels);
    final y =
        ((offset - _offsets[index]) / (_offsets[index + 1] - _offsets[index]))
            .clamp(0.0, 1.0);
    await session.commitPdfPosition(
      index,
      y: y,
      scrollToken: parent.session.scrollJump?.token,
      atEnd: _controller.offset >= _controller.position.maxScrollExtent - .5,
    );
  }

  double _bounded(double target) {
    if (!_controller.hasClients) return target;
    final position = _controller.position;
    if (!_canScroll) return position.pixels;
    final current = _indexAt(position.pixels);
    var first = current, last = current;
    while (first > 0 && _images.containsKey(first - 1)) {
      first--;
    }
    while (last < _offsets.length - 2 && _images.containsKey(last + 1)) {
      last++;
    }
    return target
        .clamp(
          _offsets[first] * _listScale,
          math.max(
            _offsets[first] * _listScale,
            _offsets[last + 1] * _listScale - position.viewportDimension,
          ),
        )
        .clamp(position.minScrollExtent, position.maxScrollExtent)
        .toDouble();
  }

  void _tick(Duration elapsed) {
    if (!_canScroll) {
      _automatic.reportAdvancing(false);
      return;
    }
    final delta = _clock.next(elapsed, _speed);
    final before = _controller.offset;
    final target = _bounded(before + delta);
    _automatic.reportAdvancing(target > before);
    _controller.jumpTo(target.toDouble());
    _warm(_indexAt(target));
    if (target >= _controller.position.maxScrollExtent - .5) {
      _automatic.finish('已到全书末尾');
    }
  }

  Future<void> volumeTurn(bool forward) async {
    if (!_canScroll) return;
    await session.beginManualReading();
    if (!mounted || !_canScroll) return;
    final position = _controller.offset;
    final scale = view.scale;
    final target = (_controller.offset + _height * .8 * (forward ? 1 : -1))
        .clamp(0.0, _maxPixels(scale));
    await _prepareViewport(target);
    if (!mounted ||
        !_canScroll ||
        view.scale != scale ||
        _controller.offset != position) {
      return;
    }
    _controller.jumpTo(target);
    await _report();
  }

  double _maxPixels(double scale) =>
      math.max(0, _offsets.last * scale - _height);

  double _clampX(double x, double scale) {
    final limit = math.max(0.0, _width * (scale - 1) / 2);
    return x.clamp(-limit, limit);
  }

  void _pan(Offset delta, Offset _) {
    if (!_canScroll) return;
    final x = _clampX(_clampX(_listX, _listScale) + delta.dx, _listScale);
    if (x != view.offset.dx) {
      _listX = x;
      view.update(view.scale, Offset(x, 0));
    }
  }

  void _zoom(double scale, Offset from, Offset to, bool singleFinger) {
    if (_jumping) return;
    if (widget.fixedView && view.editing) {
      // 调整时只变换当前视窗。固定或重置时才把位移换算进连续列表。
      final center = Offset(_width / 2, _height / 2);
      final offset = singleFinger
          ? view.fixedDrag(to - from)
          : to - center - (from - center - view.offset) * (scale / view.scale);
      view.update(
        scale,
        Offset(
          offset.dx.clamp(-center.dx * scale, center.dx * scale),
          offset.dy.clamp(-center.dy * scale, center.dy * scale),
        ),
      );
      return;
    }
    final previous = _zoomTarget;
    final oldScale = previous?.scale ?? view.scale;
    final ratio = scale / oldScale;
    final oldPixels = previous?.pixels ?? _controller.offset;
    final oldX = previous?.x ?? view.offset.dx;
    final center = _width / 2;
    _zoomTarget = (
      scale: scale,
      pixels: ((oldPixels + from.dy) * ratio - to.dy).clamp(
        0.0,
        _maxPixels(scale),
      ),
      x: _clampX(to.dx - center - (from.dx - center - oldX) * ratio, scale),
    );
    if (!_loadingZoom) unawaited(_applyZoom());
  }

  /// 已有位图时直接跟手更新。缩小时如需新页，保留旧画面并合并期间的新触点位置。
  Future<void> _applyZoom({bool confirm = false}) async {
    _loadingZoom = true;
    final version = _version;
    try {
      while (mounted && version == _version && _zoomTarget != null) {
        final target = _zoomTarget!;
        final first = _indexAt(target.pixels, scale: target.scale);
        final last = _indexAt(target.pixels + _height, scale: target.scale);
        final missing = [
          for (var i = first; i <= last; i++)
            if (!_images.containsKey(i)) _prepare(i),
        ];
        if (missing.isNotEmpty) {
          await Future.wait(missing);
          continue;
        }
        _zoomTarget = null;
        // 新的页高和视窗顶部在同一帧交接，当前位置保持在手指下方。
        _controller.position.correctPixels(target.pixels);
        _listScale = target.scale;
        _listX = target.x;
        if (confirm) {
          view.confirm(
            appliedScale: target.scale,
            landing: Offset(target.x, 0),
          );
        } else {
          view.update(target.scale, Offset(target.x, 0));
        }
        _warm(first);
      }
    } catch (e, stack) {
      if (mounted && version == _version) {
        if (confirm && view.busy) view.preparing(false);
        _zoomTarget = null;
        session.reportPositionFailure(e, stack);
      }
    } finally {
      _loadingZoom = false;
      if (mounted && version == _version) {
        if (!view.touching) _scheduleReport();
      }
    }
  }

  Future<void> confirmView(bool reset, {bool clampHorizontal = false}) async {
    if (!ready || _jumping || _loadingZoom || view.touching || view.busy) {
      return;
    }
    final scale = reset ? 1.0 : view.scale;
    final target =
        (_controller.offset + _height / 2) * scale / _listScale -
        _height / 2 -
        (reset ? 0 : view.offset.dy);
    _zoomTarget = (
      scale: scale,
      pixels: target.clamp(0.0, _maxPixels(scale)),
      x: reset
          ? 0.0
          : clampHorizontal
          ? _clampX(view.offset.dx, scale)
          : view.offset.dx,
    );
    view.preparing(true);
    await _applyZoom(confirm: true);
  }

  void _request() {
    final s = parent.session;
    final revision = (s.scrollJump?.token, _width);
    if (_requested == revision) return;
    _requested = revision;
    final version = ++_version;
    _jumping = true;
    _zoomTarget = null;
    scheduleMicrotask(() async {
      try {
        if (!mounted || version != _version) return;
        if (view.busy) view.preparing(false);
        final anchor = s.scrollJump?.locator ?? session.scrollOpeningAnchor;
        final index = anchor == null
            ? s.chapterIndex
            : widget.book.chapters.indexWhere((c) => c.id == anchor.chapterId);
        final actual = math.max(0, index);
        final content = await widget.book.content(actual);
        final y = anchor == null ? 0.0 : content.pdfPage!.yOf(anchor);
        final target =
            ((_offsets[actual] +
                        y * (_offsets[actual + 1] - _offsets[actual])) *
                    _listScale)
                .clamp(0.0, _maxPixels(_listScale));
        await _prepareViewport(target);
        if (!mounted || version != _version) return;
        await WidgetsBinding.instance.endOfFrame;
        if (!mounted || !_controller.hasClients || version != _version) return;
        _controller.jumpTo(
          target.clamp(0.0, _controller.position.maxScrollExtent),
        );
        setState(() {
          _ready = true;
          _jumping = false;
          _error = null;
        });
        await WidgetsBinding.instance.endOfFrame;
        if (!mounted || version != _version) return;
        await session.commitPdfPosition(
          actual,
          y: y,
          exact: anchor,
          scrollToken: s.scrollJump?.token,
          atEnd: target >= _controller.position.maxScrollExtent - .5,
        );
        _warm(actual);
      } catch (e, stack) {
        if (mounted && version == _version) {
          setState(() {
            _error = e;
            _jumping = false;
          });
          session.reportPositionFailure(e, stack);
        }
      }
    });
  }

  @override
  void dispose() {
    ++_version;
    _saving?.cancel();
    _ticker.dispose();
    _automatic.detach(_backend);
    _controller.dispose();
    for (final image in _images.values) {
      image.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      if (_error != null && !_ready) {
        return Center(child: Text('PDF页面无法显示：$_error'));
      }
      if (_width != constraints.maxWidth) {
        _width = constraints.maxWidth;
        _offsets = [0];
        for (final page in widget.book.file.document.pages) {
          _offsets.add(_offsets.last + _width * page.height / page.width + 8);
        }
      }
      final info = readerInformation(
        context,
        ref,
        parent.session,
        parent.settings.settings,
        parent.settings.theme,
        parent.session.chapterIndex,
        parent.session.chapterProgress,
      );
      _height = math.max(1, constraints.maxHeight - info.top - info.bottom);
      _pixels = (_width * MediaQuery.devicePixelRatioOf(context)).round().clamp(
        360,
        1600,
      );
      _request();
      // Sliver 会在布局时测量页高。每帧冻结倍率，缩放完成后由这一帧同时更新
      // 可见页、滚动范围与手指下的位置。
      final scale = _listScale;
      final preview = view.editing;
      final ratio = preview ? view.scale / scale : 1.0;
      return Stack(
        fit: StackFit.expand,
        children: [
          Positioned(
            top: info.top,
            bottom: info.bottom,
            left: 0,
            right: 0,
            child: PdfZoomSurface(
              view: view,
              fixedView: widget.fixedView,
              canStart: () => ready && !_jumping && !_loadingZoom,
              onZoom: _zoom,
              onPan: _pan,
              onEnd: _scheduleReport,
              onBegin: () {
                // 停止手指前一刻的惯性，缩放期间不滚入下一页。
                if (_controller.hasClients) {
                  _controller.jumpTo(_controller.offset);
                }
                unawaited(session.beginManualReading());
              },
              child: Listener(
                onPointerDown: (_) {
                  unawaited(session.beginManualReading());
                },
                child: GestureDetector(
                  onTap: () {
                    if (_canScroll) _automatic.centerTap();
                  },
                  child: ClipRect(
                    child: Transform(
                      alignment: Alignment.center,
                      transform: Matrix4.identity()
                        ..translateByDouble(
                          preview ? view.offset.dx - _listX * ratio : 0,
                          preview ? view.offset.dy : 0,
                          0,
                          1,
                        )
                        ..scaleByDouble(ratio, ratio, 1, 1),
                      child: CustomScrollView(
                        controller: _controller,
                        physics: _PdfReadyPhysics(limit: _bounded),
                        slivers: [
                          _PdfPagesSliver(
                            offsets: _offsets,
                            scale: scale,
                            delegate: SliverChildBuilderDelegate(
                              (_, index) => Padding(
                                padding: EdgeInsets.only(bottom: 8 * scale),
                                child: _images[index] == null
                                    ? const SizedBox.shrink()
                                    : OverflowBox(
                                        minWidth: _width * scale,
                                        maxWidth: _width * scale,
                                        child: Transform.translate(
                                          offset: Offset(
                                            widget.fixedView
                                                ? _listX
                                                : _clampX(_listX, scale),
                                            0,
                                          ),
                                          child: RawImage(
                                            image: _images[index],
                                            fit: BoxFit.fill,
                                            width: _width * scale,
                                          ),
                                        ),
                                      ),
                              ),
                              childCount: widget.book.chapters.length,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          IgnorePointer(
            child: CustomPaint(painter: _PdfScrollInformation(info)),
          ),
        ],
      );
    },
  );
}

int _pdfPageAt(List<double> offsets, double pixels) {
  var low = 0, high = offsets.length - 2;
  while (low < high) {
    final mid = (low + high + 1) ~/ 2;
    if (offsets[mid] <= pixels) {
      low = mid;
    } else {
      high = mid - 1;
    }
  }
  return low;
}

/// 页高来自 PDF 元数据。直接用累计页高定位，缩放时无需逐页测量到当前页。
class _PdfPagesSliver extends SliverMultiBoxAdaptorWidget {
  const _PdfPagesSliver({
    required this.offsets,
    required this.scale,
    required super.delegate,
  });

  final List<double> offsets;
  final double scale;

  @override
  _RenderPdfPages createRenderObject(BuildContext context) => _RenderPdfPages(
    offsets,
    scale,
    childManager: context as SliverMultiBoxAdaptorElement,
  );

  @override
  void updateRenderObject(BuildContext context, _RenderPdfPages renderObject) {
    renderObject.updateGeometry(offsets, scale);
  }
}

class _RenderPdfPages extends RenderSliverFixedExtentBoxAdaptor {
  _RenderPdfPages(this._offsets, this._scale, {required super.childManager});

  List<double> _offsets;
  double _scale;

  void updateGeometry(List<double> offsets, double scale) {
    if (identical(offsets, _offsets) && scale == _scale) return;
    _offsets = offsets;
    _scale = scale;
    markNeedsLayout();
  }

  @override
  double? get itemExtent => null;

  @override
  ItemExtentBuilder get itemExtentBuilder =>
      (index, _) => (_offsets[index + 1] - _offsets[index]) * _scale;

  @override
  double indexToLayoutOffset(double itemExtent, int index) =>
      _offsets[index] * _scale;

  @override
  int getMinChildIndexForScrollOffset(double scrollOffset, double itemExtent) =>
      _pdfPageAt(_offsets, scrollOffset / _scale);

  @override
  int getMaxChildIndexForScrollOffset(double scrollOffset, double itemExtent) =>
      _pdfPageAt(_offsets, scrollOffset / _scale);

  @override
  double computeMaxScrollOffset(
    SliverConstraints constraints,
    double itemExtent,
  ) => _offsets.last * _scale;

  @override
  double estimateMaxScrollOffset(
    SliverConstraints constraints, {
    int? firstIndex,
    int? lastIndex,
    double? leadingScrollOffset,
    double? trailingScrollOffset,
  }) => _offsets.last * _scale;
}

class _PdfReadyPhysics extends ClampingScrollPhysics {
  const _PdfReadyPhysics({required this.limit, super.parent});
  final double Function(double) limit;
  @override
  _PdfReadyPhysics applyTo(ScrollPhysics? ancestor) =>
      _PdfReadyPhysics(limit: limit, parent: buildParent(ancestor));
  @override
  double applyBoundaryConditions(ScrollMetrics position, double value) {
    final normal = super.applyBoundaryConditions(position, value);
    if (normal != 0) return normal;
    return value - limit(value);
  }
}

class _PdfScrollInformation extends CustomPainter {
  _PdfScrollInformation(this.info);
  final PageInformation info;
  @override
  void paint(Canvas canvas, Size size) => info.paint(canvas, size);
  @override
  bool shouldRepaint(_PdfScrollInformation old) =>
      old.info.paintingKey != info.paintingKey;
}
