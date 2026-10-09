part of 'simplified_scroll_area.dart';

/// 每帧只改可见位置，不重排、不写数据库；图片和补章完成后继续有效计时。
mixin _SimplifiedAutomaticMotion on ConsumerState<SimplifiedScrollArea>, TickerProvider {
  ScrollWindow get _window;
  ScrollResources get _resources;
  ReaderSessionNotifier get _session;
  set _chapterFailed(bool value);
  late AutomaticReadingNotifier _automatic;
  late AutomaticScrollBackend _autoBackend;
  late Ticker _autoTicker;
  final _clock = FrameScrollDistance();
  double _speed = 24;
  Future<void>? _warming;

  void _initAutomatic() {
    _automatic = ref.read(automaticReadingProvider(widget.bookId).notifier);
    _autoTicker = createTicker(_tickAutomatic);
    _autoBackend = AutomaticScrollBackend(
      ready: () => _window.controller.hasClients && _window.isReady && !_window.busy,
      start: (speed) async {
        _chapterFailed = false;
        await _window.maintain();
        _window.controller.jumpTo(_window.controller.offset);
        _speed = speed; _clock.reset(); _autoTicker.start();
      },
      stop: () async {
        _autoTicker.stop(); _clock.reset();
        if (_window.controller.hasClients) {
          _window.controller.jumpTo(_window.controller.offset);
          _window.report();
        }
      },
      speed: (speed) => _speed = speed,
    );
    _automatic.attach(_autoBackend);
  }

  void _tickAutomatic(Duration elapsed) {
    final delta = _clock.next(elapsed, _speed,
      waiting: _window.busy || !_window.isReady || _warming != null || !_window.controller.hasClients);
    if (delta == 0) { _automatic.reportAdvancing(false); return; }
    final visible = _window.visible(), options = _window.options;
    if (visible == null || options == null) { _automatic.reportAdvancing(false); return; }
    if (!_resources.ready(visible.entry.layout, visible.local + delta, options.contentHeight)) {
      _automatic.reportAdvancing(false);
      _warming = _resources.warm(visible.entry.layout, visible.local + delta,
        options.contentHeight).whenComplete(() {
          _warming = null;
          if (mounted) setState(() {});
        });
      return;
    }
    final position = _window.controller.position;
    // 懒列表的 maxScrollExtent 是估算值，书末必须用已测量的真实总高度。
    final end = math.max(0.0, _window.height - position.viewportDimension);
    final target = math.min(end, _window.controller.offset + delta);
    _automatic.reportAdvancing(target != _window.controller.offset);
    if (target >= end &&
        _window.entries.last.index == widget.session.chapters.length - 1) {
      _window.controller.jumpTo(target);
      _automatic.finish('已到全书末尾');
      return;
    }
    _window.controller.jumpTo(target);
  }

  void _disposeAutomatic() {
    final running = _autoTicker.isActive;
    _autoTicker.dispose();
    if (running && _window.controller.hasClients) {
      _window.report(); unawaited(_session.persist());
    }
    _automatic.detach(_autoBackend);
  }
}
