part of 'pdf_reader_area.dart';

class _PdfScroll extends ConsumerStatefulWidget {
  const _PdfScroll({super.key, required this.parent, required this.book});
  final PdfReaderArea parent;
  final PdfBookController book;
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
  final _offsets = <double>[0];
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
  double _fixedScale = 1, _fixedX = 0;
  bool get ready => _ready && _controller.hasClients && _error == null;
  PdfReaderArea get parent => widget.parent;
  ReaderSessionNotifier get session =>
      ref.read(readerSessionProvider(parent.bookId).notifier);
  PdfViewport get view => ref.read(pdfViewportProvider(parent.bookId));

  @override
  void initState() {
    super.initState();
    _fixedScale = view.scale;
    _fixedX = view.offset.dx;
    view.offset = Offset(_fixedX, 0);
    _controller.addListener(_moved);
    _backend = AutomaticScrollBackend(
      ready: () => ready && view.canTurn,
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

  int _indexAt(double offset) {
    var low = 0, high = _offsets.length - 2;
    while (low < high) {
      final mid = (low + high + 1) ~/ 2;
      if (_offsets[mid] <= offset) {
        low = mid;
      } else {
        high = mid - 1;
      }
    }
    return low;
  }

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
        : _offsets[index];
    final last = math.max(
      index + 2,
      _indexAt(math.min(_offsets.last, offset + _height)) + 1,
    );
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
    final last = _indexAt(math.min(_offsets.last, offset + _height));
    await Future.wait([
      for (var i = first - 1; i <= last + 1; i++) _prepare(i),
    ]);
  }

  void _moved() {
    if (!_ready || _jumping || !view.canTurn || !_controller.hasClients) return;
    final index = _indexAt(_controller.offset);
    _warm(index);
    _saving?.cancel();
    _saving = Timer(
      const Duration(milliseconds: 150),
      () => unawaited(_report()),
    );
  }

  Future<void> _report() async {
    if (!_ready || _jumping || !view.canTurn || !_controller.hasClients) return;
    final offset = _controller.offset;
    final index = _indexAt(offset);
    final y =
        ((offset - _offsets[index]) / (_offsets[index + 1] - _offsets[index]))
            .clamp(0.0, 1.0);
    await session.commitPdfPosition(
      index,
      y: y,
      scrollToken: parent.session.scrollJump?.token,
      atEnd: offset >= _controller.position.maxScrollExtent - .5,
    );
  }

  double _bounded(double target) {
    if (!_controller.hasClients) return target;
    final position = _controller.position;
    final current = _indexAt(position.pixels.clamp(0.0, _offsets.last));
    var first = current, last = current;
    while (first > 0 && _images.containsKey(first - 1)) {
      first--;
    }
    while (last < _offsets.length - 2 && _images.containsKey(last + 1)) {
      last++;
    }
    return target
        .clamp(
          _offsets[first],
          math.max(
            _offsets[first],
            _offsets[last + 1] - position.viewportDimension,
          ),
        )
        .clamp(position.minScrollExtent, position.maxScrollExtent)
        .toDouble();
  }

  void _tick(Duration elapsed) {
    if (!ready || !view.canTurn) {
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
    if (!ready || !view.canTurn) return;
    await session.beginManualReading();
    final target = (_controller.offset + _height * .8 * (forward ? 1 : -1))
        .clamp(0.0, math.max(0.0, _offsets.last - _height));
    await _prepareViewport(target.toDouble());
    if (mounted) _controller.jumpTo(target.toDouble());
    await _report();
  }

  List<double> _pageOffsets(double scale) {
    final result = <double>[0];
    for (final page in widget.book.file.document.pages) {
      result.add(result.last + (_width * page.height / page.width + 8) * scale);
    }
    return result;
  }

  /// 调整中只变换当前窗口。确认时先备好接续后会露出的页面，再一次交接几何与位置。
  Future<void> confirmView(bool reset) async {
    if (!ready || view.busy || view.touching) return;
    view.preparing(true);
    try {
      final scale = reset ? 1.0 : view.scale;
      final ratio = scale / _fixedScale;
      final offsets = _pageOffsets(scale);
      final shiftY = reset ? 0.0 : view.offset.dy;
      final target =
          ((_controller.offset + _height / 2) * ratio - _height / 2 - shiftY)
              .clamp(0.0, math.max(0.0, offsets.last - _height))
              .toDouble();
      var first = 0;
      while (first + 1 < offsets.length - 1 && offsets[first + 1] <= target) {
        first++;
      }
      var last = first;
      while (last + 1 < offsets.length - 1 &&
          offsets[last + 1] < target + _height) {
        last++;
      }
      await Future.wait([for (var i = first; i <= last; i++) _prepare(i)]);
      if (!mounted) return;
      setState(() {
        _fixedScale = scale;
        _fixedX = reset ? 0 : view.offset.dx;
        _offsets
          ..clear()
          ..addAll(offsets);
        // 布局前修改偏移，避免先按旧位置画一帧再jumpTo造成上下跳变。
        _controller.position.correctPixels(target);
        view.confirm(reset: reset, scroll: true);
      });
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      _warm(_indexAt(target));
      await _report();
    } catch (e, stack) {
      if (mounted) {
        view.preparing(false);
        session.reportPositionFailure(e, stack);
      }
    }
  }

  void _request() {
    final s = parent.session;
    final revision = (s.scrollJump?.token, _width);
    if (_requested == revision) return;
    _requested = revision;
    final version = ++_version;
    _jumping = true;
    scheduleMicrotask(() async {
      try {
        final anchor = s.scrollJump?.locator ?? session.scrollOpeningAnchor;
        final index = anchor == null
            ? s.chapterIndex
            : widget.book.chapters.indexWhere((c) => c.id == anchor.chapterId);
        final actual = math.max(0, index);
        final content = await widget.book.content(actual);
        final y = anchor == null ? 0.0 : content.pdfPage!.yOf(anchor);
        final target =
            (_offsets[actual] + y * (_offsets[actual + 1] - _offsets[actual]))
                .clamp(0.0, math.max(0.0, _offsets.last - _height))
                .toDouble();
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
        _offsets
          ..clear()
          ..addAll(_pageOffsets(_fixedScale));
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
              onEnd: () {
                // 手动缩回原大小也要还原列表页高，不能只还原外层变换。
                if (!view.editing && (_fixedScale != 1 || _fixedX != 0)) {
                  unawaited(confirmView(true));
                }
              },
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
                  onTap: _automatic.centerTap,
                  child: ClipRect(
                    child: Transform(
                      alignment: Alignment.center,
                      transform: Matrix4.identity()
                        ..translateByDouble(
                          view.offset.dx - _fixedX * view.scale / _fixedScale,
                          view.offset.dy,
                          0,
                          1,
                        )
                        ..scaleByDouble(
                          view.scale / _fixedScale,
                          view.scale / _fixedScale,
                          1,
                          1,
                        ),
                      child: ListView.builder(
                        controller: _controller,
                        physics: _PdfReadyPhysics(limit: _bounded),
                        itemCount: widget.book.chapters.length,
                        // 缩放会同时改变所有页高；按已知尺寸定位，不能沿用
                        // 普通SliverList在缩放前缓存的子项起点。
                        itemExtentBuilder: (index, _) =>
                            _offsets[index + 1] - _offsets[index],
                        itemBuilder: (_, index) => SizedBox(
                          height: _offsets[index + 1] - _offsets[index],
                          child: Padding(
                            padding: EdgeInsets.only(bottom: 8 * _fixedScale),
                            child: _images[index] == null
                                ? const SizedBox.shrink()
                                : OverflowBox(
                                    minWidth: _width * _fixedScale,
                                    maxWidth: _width * _fixedScale,
                                    child: Transform.translate(
                                      offset: Offset(_fixedX, 0),
                                      child: RawImage(
                                        image: _images[index],
                                        fit: BoxFit.fill,
                                        width: _width * _fixedScale,
                                      ),
                                    ),
                                  ),
                          ),
                        ),
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
