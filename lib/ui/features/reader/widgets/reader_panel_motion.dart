import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import '../../../core/widgets/frame_fade.dart';

/// 工具栏尺寸供控制层、主面板与子面板共用，弹层的底边始终贴在工具栏上沿。
const readerToolbarHeight = 87.0;
const readerPanelEnterDuration = Duration(milliseconds: 220);
const readerPanelExitDuration = Duration(milliseconds: 180);
const readerProgressCollapseDuration = Duration(milliseconds: 120);

double readerPanelBottom(BuildContext context) => math.max(
  readerToolbarHeight + MediaQuery.viewPaddingOf(context).bottom,
  MediaQuery.viewInsetsOf(context).bottom,
);

/// 裁切边界就是工具栏上沿，滑出的面板不会越过这条边界盖住工具栏。
class ReaderPanelViewport extends StatelessWidget {
  const ReaderPanelViewport({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return Positioned(
      left: 0,
      right: 0,
      top: media.padding.top,
      // 原生 WebView 与 Flutter 分别取整绘制边界；重叠一个物理像素，
      // 避免小数安全区或像素密度在面板和工具栏之间留下透明细线。
      bottom: readerPanelBottom(context) - 1 / media.devicePixelRatio,
      child: ClipRect(
        child: MediaQuery(
          data: media.copyWith(
            size: Size(
              media.size.width,
              math.max(
                0,
                media.size.height -
                    readerPanelBottom(context) -
                    media.padding.top,
              ),
            ),
            padding: EdgeInsets.zero,
            viewInsets: EdgeInsets.zero,
          ),
          child: FrameFade(revision: Theme.of(context).scaffoldBackgroundColor,
            child: Align(alignment: Alignment.bottomCenter, child: child)),
        ),
      ),
    );
  }
}

/// 收起到 80% 时开始下一层；easeInCubic 的剩余位置为 (1-t)^3。
const readerPanelHandoffDuration = Duration(milliseconds: 75);

/// 旧层在独立动画中继续退出，新层可以在旧层上方开始进入。
class ReaderPanelMotion extends StatefulWidget {
  const ReaderPanelMotion({
    super.key,
    required this.panel,
    required this.child,
    this.delayOpening = false,
  });
  final Object? panel;
  final Widget? child;
  final bool delayOpening;
  @override
  State<ReaderPanelMotion> createState() => _ReaderPanelMotionState();
}

class _ReaderPanelMotionState extends State<ReaderPanelMotion> {
  Widget? _shown;
  Object? _panel;
  Timer? _timer;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_shown == null && widget.panel != null) {
      // 首次显示也从屏幕下方进入。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _present();
      });
    }
  }

  void _present() => setState(() {
    _panel = widget.panel;
    _shown = widget.child;
  });

  @override
  void didUpdateWidget(ReaderPanelMotion old) {
    super.didUpdateWidget(old);
    if (old.panel == widget.panel) {
      if (_panel == widget.panel) _shown = widget.child;
      return;
    }
    _timer?.cancel();
    final reduced = MediaQuery.disableAnimationsOf(context);
    final delay = old.panel == null && old.delayOpening
        ? readerProgressCollapseDuration
        : Duration.zero;
    if (widget.panel == null || reduced || delay == Duration.zero) {
      _present();
    } else {
      _panel = null;
      _shown = null;
      _timer = Timer(delay, _present);
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedSwitcher(
    duration: MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : readerPanelEnterDuration,
    reverseDuration: MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : readerPanelExitDuration,
    switchInCurve: Curves.easeOutCubic,
    switchOutCurve: Curves.easeInCubic,
    layoutBuilder: (current, previous) => Stack(
      alignment: Alignment.bottomCenter,
      children: [...previous, ?current],
    ),
    transitionBuilder: (child, animation) => FadeTransition(
      opacity: animation,
      child: SlideTransition(
        position: Tween(
          begin: const Offset(0, 1),
          end: Offset.zero,
        ).animate(animation),
        child: child,
      ),
    ),
    child: _shown == null
        ? const SizedBox.shrink()
        : IgnorePointer(
            key: ValueKey(_panel),
            ignoring: widget.panel != _panel,
            child: _shown,
          ),
  );
}

/// 控制层进入时上栏向下、底栏向上；退出时反向滑出并淡出，不改变正文尺寸。
class ReaderControlsEntrance extends StatefulWidget {
  const ReaderControlsEntrance({
    super.key,
    required this.child,
    this.top = false,
    this.visible = true,
  });
  final Widget child;
  final bool top, visible;
  @override
  State<ReaderControlsEntrance> createState() => _ControlsEntranceState();
}

class _ControlsEntranceState extends State<ReaderControlsEntrance>
    with SingleTickerProviderStateMixin {
  late final _animation = AnimationController(
    vsync: this,
    duration: readerPanelEnterDuration,
    reverseDuration: readerPanelExitDuration,
  );
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _update();
  }

  @override
  void didUpdateWidget(ReaderControlsEntrance old) {
    super.didUpdateWidget(old);
    if (old.visible != widget.visible) _update();
  }

  void _update() {
    if (MediaQuery.disableAnimationsOf(context)) {
      _animation.value = widget.visible ? 1 : 0;
    } else if (widget.visible) {
      _animation.forward();
    } else {
      _animation.reverse();
    }
  }

  @override
  void dispose() {
    _animation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _animation,
    child: FrameFade(revision: Theme.of(context).scaffoldBackgroundColor,
      child: widget.child),
    builder: (context, child) {
      final value = (widget.visible ? Curves.easeOutCubic : Curves.easeInCubic)
          .transform(_animation.value);
      return IgnorePointer(
        ignoring: !widget.visible,
        child: FractionalTranslation(
          translation: Offset(0, (widget.top ? -1 : 1) * (1 - value)),
          child: Opacity(opacity: value, child: child),
        ),
      );
    },
  );
}
