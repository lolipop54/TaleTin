import 'dart:async';

import 'turn_trace.dart';

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../../core/widgets/book_loading.dart';
import '../../../core/widgets/frame_fade.dart';

typedef NativeReadingFrame = ({ui.Image image, Rect bounds});

/// 先留下旧正文图像，再准备新显示；新位置和画面都就绪才撤掉遮盖。
class ReaderDisplayTransition extends StatefulWidget {
  static Future<void> captureForJump(GlobalKey key) async {
    final state = key.currentState;
    if (state is _ReaderDisplayTransitionState) {
      await state._captureForJump();
    }
  }

  static Future<void> finishJump(GlobalKey key) async {
    final state = key.currentState;
    if (state is _ReaderDisplayTransitionState) await state._finished?.future;
  }

  const ReaderDisplayTransition({
    super.key,
    required this.display,
    required this.child,
    required this.ready,
    required this.captureNative,
    this.loadingBackground,
    this.loadingRevision,
    this.reflow,
    this.viewport,
    this.appearance,
    this.onReadable,
  });
  final Object display;

  /// 字体、字号和间距重排仍只保留旧页，不增加淡化。
  final Object? reflow;
  final Object? appearance;

  /// 简化／原书排版切换显示加载动画；其它重排仍按原规则保留旧画面。
  final Object? loadingRevision;
  final VoidCallback? onReadable;
  final Size? viewport;
  final Widget child;
  final bool Function() ready;
  final Future<NativeReadingFrame?> Function() captureNative;
  final Color? loadingBackground;
  @override
  State<ReaderDisplayTransition> createState() =>
      _ReaderDisplayTransitionState();
}

class _ReaderDisplayTransitionState extends State<ReaderDisplayTransition>
    with SingleTickerProviderStateMixin {
  late final _opacity = AnimationController(
    vsync: this,
    value: 1,
    duration: pageFadeDuration,
  );
  Completer<void>? _finished;
  bool _smooth = false, _revealing = false;
  final _boundary = GlobalKey();
  late Widget _shown = widget.child;
  late Size? _shownSize = widget.viewport;

  void _showLatest() {
    _shown = widget.child;
    _shownSize = widget.viewport;
  }

  ui.Image? _cover;
  bool _capturing = false;
  bool _loading = false;
  bool _opening = false;
  int _version = 0;
  Timer? _check;

  Future<void> _captureForJump() async {
    _finished ??= Completer<void>();
    _smooth = true;
    _revealing = false;
    _opacity.stop();
    _opacity.value = 1;
    try {
      await _capture(widget.captureNative);
    } catch (_) {
      _finished?.complete();
      _finished = null;
      rethrow;
    }
    // 同章 WebView 跳转也必须等旧图盖住后才能开始改变位置。
    await WidgetsBinding.instance.endOfFrame;
  }

  @override
  void initState() {
    super.initState();
    // 路由负责开书加载层的淡出，内层首屏不重复播放第二段淡化。
    _loading = widget.loadingBackground != null && !widget.ready();
    _opening = _loading;
    _smooth = _loading;
    _scheduleReady();
  }

  @override
  void didUpdateWidget(ReaderDisplayTransition old) {
    super.didUpdateWidget(old);
    if (old.loadingRevision != widget.loadingRevision &&
        widget.loadingBackground != null) {
      // 模式切换先盖加载层，再让新正文布局，不截取或显示准备中的页面。
      ++_version;
      _opacity.stop();
      _opacity.value = 1;
      _capturing = _revealing = false;
      _loading = _smooth = true;
      final cover = _cover;
      _cover = null;
      WidgetsBinding.instance.addPostFrameCallback((_) => cover?.dispose());
      _showLatest();
    } else if (old.display != widget.display ||
        old.appearance != widget.appearance) {
      traceTurn('load display-change ${widget.display}');
      _smooth = true;
      unawaited(_capture(old.captureNative));
    } else if (old.reflow != widget.reflow || old.viewport != widget.viewport) {
      unawaited(_capture(old.captureNative));
    } else if (!_capturing) {
      _showLatest();
    }
    _scheduleReady();
  }

  Future<void> _capture(Future<NativeReadingFrame?> Function() native) async {
    // 连续调整时继续保留最初的确认画面，不再截取尚未准备好的中间正文。
    // 系统栏/字体设置在首屏准备中到达时，不能把正在跳动的方块截成静图。
    if (_loading) {
      _showLatest();
      _scheduleReady();
      return;
    }
    if (_capturing) return;
    _opacity.stop();
    _opacity.value = 1;
    _revealing = false;
    ++_version;
    if (_cover != null) {
      _showLatest();
      _scheduleReady();
      return;
    }
    final version = _version;
    _capturing = true;
    final boundary =
        _boundary.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final size = boundary.size;
    // Flutter 画布保留上下信息；原生正文另外取得，避免平台视图截图缺正文。
    final ratio = MediaQuery.devicePixelRatioOf(context);
    final base = await traceTurnStep(
      'load capture-flutter',
      () => boundary.toImage(pixelRatio: ratio),
    );
    final NativeReadingFrame? frame;
    try {
      frame = await traceTurnStep('load capture-native', native);
    } catch (_) {
      base.dispose();
      _capturing = false;
      if (mounted) setState(_showLatest);
      rethrow;
    }
    ui.Image image = base;
    if (frame != null) {
      final recorder = ui.PictureRecorder();
      // 单独录制整页，原生正文按原位置覆盖进去。
      final pageCanvas = Canvas(recorder)..scale(ratio);
      pageCanvas.drawImageRect(
        base,
        Rect.fromLTWH(0, 0, base.width.toDouble(), base.height.toDouble()),
        Offset.zero & size,
        Paint(),
      );
      pageCanvas.drawImageRect(
        frame.image,
        Offset.zero &
            Size(frame.image.width.toDouble(), frame.image.height.toDouble()),
        frame.bounds,
        Paint(),
      );
      final picture = recorder.endRecording();
      image = await picture.toImage(
        (size.width * ratio).ceil(),
        (size.height * ratio).ceil(),
      );
      picture.dispose();
      frame.image.dispose();
      base.dispose();
    }
    if (!mounted || version != _version) {
      image.dispose();
      return;
    }
    setState(() {
      _cover?.dispose();
      _cover = image;
      _capturing = false;
      _showLatest();
    });
    _scheduleReady();
  }

  void _scheduleReady() {
    if ((_cover == null && !_loading) ||
        _capturing ||
        _check != null ||
        _revealing) {
      return;
    }
    _check = Timer(const Duration(milliseconds: 16), () {
      _check = null;
      if (!mounted) return;
      if (!widget.ready()) {
        _scheduleReady();
        return;
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !widget.ready()) {
          _scheduleReady();
          return;
        }
        traceTurn('load display-readable ${widget.display}');
        unawaited(_reveal());
      });
      WidgetsBinding.instance.scheduleFrame();
    });
  }

  Future<void> _reveal() async {
    if (_revealing) return;
    _revealing = true;
    final version = _version;
    final cover = _cover;
    if (_smooth &&
        (cover != null ||
            (_loading && (!_opening || widget.onReadable == null))) &&
        !MediaQuery.disableAnimationsOf(context)) {
      try {
        await _opacity.reverse(from: 1).orCancel;
      } on TickerCanceled {
        return;
      }
    }
    if (!mounted || version != _version) return;
    final finished = _finished;
    _finished = null;
    setState(() {
      _cover = null;
      _loading = false;
      _opening = false;
      _smooth = false;
      _revealing = false;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      cover?.dispose();
      finished?.complete();
      if (mounted) widget.onReadable?.call();
    });
  }

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      // 旋转时先在旧尺寸下截图，再把新约束交给正文，避免先重排后才记位置。
      Positioned.fill(
        child: OverflowBox(
          alignment: Alignment.topLeft,
          minWidth: _shownSize?.width,
          maxWidth: _shownSize?.width,
          minHeight: _shownSize?.height,
          maxHeight: _shownSize?.height,
          child: RepaintBoundary(key: _boundary, child: _shown),
        ),
      ),
      if (_cover != null)
        Positioned.fill(
          child: AbsorbPointer(
            child: FadeTransition(
              opacity: _opacity,
              child: RawImage(image: _cover, fit: BoxFit.fill),
            ),
          ),
        ),
      if (_loading)
        Positioned.fill(
          child: AbsorbPointer(
            child: FadeTransition(
              opacity: _opacity,
              child: ColoredBox(
                color: widget.loadingBackground!,
                child: Center(
                  child: BookLoading(label: _opening ? '打开书籍中...' : '切换排版中...'),
                ),
              ),
            ),
          ),
        ),
    ],
  );

  @override
  void dispose() {
    ++_version;
    _check?.cancel();
    _opacity.dispose();
    _cover?.dispose();
    _finished?.complete();
    _finished = null;
    super.dispose();
  }
}
