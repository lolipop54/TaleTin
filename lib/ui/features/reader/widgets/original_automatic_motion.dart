part of 'original_scroll_area.dart';

/// 开始前停原生惯性，暂停后直接取最终 DOM 位置，再交给同一保存入口。
mixin _OriginalAutomaticMotion on ConsumerState<OriginalScrollArea> {
  InAppWebViewController? get host;
  bool get _ready;
  int get _request;
  Future<Object?> _message(Map<String, dynamic> raw);
  late AutomaticReadingNotifier _automatic;
  late AutomaticScrollBackend _autoBackend;
  int _autoGeneration = 0;

  Future<void> _stopNativeScroll() async {
    final controller = host;
    if (controller == null) return;
    const channel = MethodChannel('gtreader/page_capture');
    await channel.invokeMethod<void>('stopFling', {'viewId': controller.getViewId()});
  }

  void _initAutomatic() {
    _automatic = ref.read(automaticReadingProvider(widget.bookId).notifier);
    _autoBackend = AutomaticScrollBackend(
      ready: () => _ready && host != null,
      start: (speed) async {
        final generation = ++_autoGeneration;
        await _stopNativeScroll();
        await host!.evaluateJavascript(source: 'gtScroll.startAuto($speed,$generation)');
      },
      stop: () async {
        ++_autoGeneration; // 作废旧 JS 状态回报，不能让已暂停的下一轮误记推进。
        final controller = host;
        if (!mounted || controller == null) return;
        // 先停浏览器推进，再等原生画面；等待期间不能继续走自动阅读距离。
        await controller.evaluateJavascript(source: 'window.gtScroll?.stopAuto()');
        if (!mounted) return;
        await _stopNativeScroll();
        if (!mounted) return;
        // 息屏后没有实际绘制帧，但 JS 已停下；此时直接取最终 DOM 位置保存。
        if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
          await OriginalHostController.fromWebView(controller).presented();
        }
        if (!mounted) return;
        final raw = await controller.evaluateJavascript(source:
          'window.gtScroll ? JSON.stringify(gtScroll.anchor()) : null');
        if (!mounted || raw is! String) return;
        final point = jsonDecode(raw);
        if (point is Map) {
          await _message({'type': 'position', 'request': _request, 'point': point});
        }
      },
      speed: (speed) {
        if (host != null) {
          unawaited(host!.evaluateJavascript(source: 'gtScroll.auto.speed=$speed'));
        }
      },
    );
    _automatic.attach(_autoBackend);
  }

  void _disposeAutomatic() => _automatic.detach(_autoBackend);
}
