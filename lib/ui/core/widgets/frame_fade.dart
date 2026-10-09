import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

const pageFadeDuration = Duration(milliseconds: 200);

/// 保存上一次已经画出的 Flutter 画面，不复制带 Provider、滚动状态的子树。
/// 平台视图必须使用阅读器自己的原生截图交接，不能使用这个组件截图。
ui.Image? captureFlutterFrame(GlobalKey key) {
  final boundary = key.currentContext?.findRenderObject();
  if (boundary is! RenderRepaintBoundary ||
      !boundary.hasSize ||
      boundary.size.isEmpty) {
    return null;
  }
  return boundary.toImageSync(
    pixelRatio: MediaQuery.devicePixelRatioOf(key.currentContext!),
  );
}

class FrameFade extends StatefulWidget {
  const FrameFade({super.key, required this.revision, required this.child});
  final Object? revision;
  final Widget child;
  @override
  State<FrameFade> createState() => FrameFadeState();
}

class FrameFadeState extends State<FrameFade>
    with SingleTickerProviderStateMixin {
  final _boundary = GlobalKey();
  late final _opacity = AnimationController(
    vsync: this,
    duration: pageFadeDuration,
  );
  ui.Image? _cover;
  int _version = 0;
  bool get busy => _cover != null;

  @override
  void didUpdateWidget(FrameFade oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.revision == widget.revision ||
        MediaQuery.disableAnimationsOf(context)) {
      return;
    }
    // didUpdate 在新子树绘制前调用，此时图层仍是上一帧的完整画面。
    _cover ??= captureFlutterFrame(_boundary);
    if (_cover == null) return;
    final version = ++_version;
    _opacity.value = 1;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || version != _version) return;
      try {
        await _opacity.reverse(from: 1).orCancel;
      } on TickerCanceled {
        return;
      }
      if (!mounted || version != _version) return;
      final image = _cover;
      setState(() => _cover = null);
      WidgetsBinding.instance.addPostFrameCallback((_) => image?.dispose());
    });
  }

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.passthrough,
    children: [
      RepaintBoundary(key: _boundary, child: widget.child),
      if (_cover != null)
        Positioned.fill(
          child: AbsorbPointer(
            child: FadeTransition(
              opacity: _opacity,
              child: RawImage(image: _cover, fit: BoxFit.fill),
            ),
          ),
        ),
    ],
  );

  @override
  void dispose() {
    ++_version;
    _opacity.dispose();
    _cover?.dispose();
    super.dispose();
  }
}
