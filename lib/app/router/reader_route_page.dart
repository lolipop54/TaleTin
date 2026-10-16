import 'package:flutter/material.dart';

import '../../ui/core/widgets/book_loading.dart';
import '../../ui/core/widgets/frame_fade.dart';
import '../../core/diagnostics/reader_work_trace.dart';

class ReaderRoutePage extends Page<void> {
  const ReaderRoutePage({super.key, required this.child, this.bookId});
  final Widget child;
  final String? bookId;
  @override
  Route<void> createRoute(BuildContext context) {
    return PageRouteBuilder<void>(
      settings: this,
      opaque: false,
      transitionDuration: Duration.zero,
      reverseTransitionDuration: pageFadeDuration,
      pageBuilder: (_, _, _) => _ReaderEntrance(bookId: bookId, child: child),
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
  const _ReaderEntrance({required this.child, this.bookId});
  final Widget child;
  final String? bookId;
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
  final _opening = ReaderWorkTrace.start('reader.open');
  @override
  void initState() {
    super.initState();
    final id = widget.bookId;
    if (id != null) {
      BookOpeningTrace.begin(id);
      BookOpeningTrace.mark(id, 'route_created');
    }
  }

  Future<void> _reveal() async {
    if (_ready || _revealing) return;
    _revealing = true;
    _opening?.mark('first_frame_ready');
    if (widget.bookId case final String id) {
      BookOpeningTrace.mark(id, 'first_frame_ready');
    }
    if (!MediaQuery.disableAnimationsOf(context)) {
      try {
        await _opacity.reverse(from: 1).orCancel;
      } on TickerCanceled {
        return;
      }
    }
    if (!mounted) return;
    _opening?.mark('reveal_animation');
    _opening?.finish();
    setState(() => _ready = true);
    if (readerWorkTraceEnabled) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (widget.bookId case final String id) {
          BookOpeningTrace.mark(id, 'loading_layer_removed');
          BookOpeningTrace.finish(id);
        }
      });
    }
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
    if (widget.bookId case final String id) {
      BookOpeningTrace.finish(id, status: _ready ? 'ok' : 'disposed');
    }
    _opening?.finish(status: _ready ? 'ok' : 'disposed');
    _opacity.dispose();
    super.dispose();
  }
}
