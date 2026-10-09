import 'package:flutter/material.dart';

import '../../ui/core/widgets/book_loading.dart';
import '../../ui/core/widgets/frame_fade.dart';

class ReaderRoutePage extends Page<void> {
  const ReaderRoutePage({super.key, required this.child});
  final Widget child;
  @override
  Route<void> createRoute(BuildContext context) {
    return PageRouteBuilder<void>(
      settings: this,
      opaque: false,
      transitionDuration: Duration.zero,
      reverseTransitionDuration: pageFadeDuration,
      pageBuilder: (_, _, _) => _ReaderEntrance(child: child),
      transitionsBuilder: (context, animation, _, child) =>
          MediaQuery.disableAnimationsOf(context)
          ? child
          : FadeTransition(opacity: animation, child: child),
    );
  }
}

class ReaderPageReady extends InheritedWidget {
  const ReaderPageReady({
    super.key,
    required this.onReady,
    required super.child,
  });
  final VoidCallback onReady;
  static VoidCallback? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ReaderPageReady>()?.onReady;
  @override
  bool updateShouldNotify(ReaderPageReady oldWidget) => false;
}

class _ReaderEntrance extends StatefulWidget {
  const _ReaderEntrance({required this.child});
  final Widget child;
  @override
  State<_ReaderEntrance> createState() => _ReaderEntranceState();
}

class _ReaderEntranceState extends State<_ReaderEntrance>
    with SingleTickerProviderStateMixin {
  late final _opacity = AnimationController(
    vsync: this,
    value: 1,
    duration: pageFadeDuration,
  );
  bool _ready = false, _revealing = false;
  Future<void> _reveal() async {
    if (_ready || _revealing) return;
    _revealing = true;
    if (!MediaQuery.disableAnimationsOf(context)) {
      try {
        await _opacity.reverse(from: 1).orCancel;
      } on TickerCanceled {
        return;
      }
    }
    if (!mounted) return;
    setState(() => _ready = true);
  }

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      ReaderPageReady(onReady: _reveal, child: widget.child),
      if (!_ready)
        Positioned.fill(
          child: AbsorbPointer(
            child: FadeTransition(
              opacity: _opacity,
              // 首屏在不透明加载层下完成排版和绘制，就绪回调到达后才揭开。
              child: ColoredBox(
                color: Theme.of(context).scaffoldBackgroundColor,
                child: const Center(child: BookLoading(label: '打开书籍中...')),
              ),
            ),
          ),
        ),
    ],
  );
  @override
  void dispose() {
    _opacity.dispose();
    super.dispose();
  }
}
