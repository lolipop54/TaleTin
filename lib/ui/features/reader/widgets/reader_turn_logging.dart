import 'package:flutter/widgets.dart';

import '../../../../core/diagnostics/reader_turn_diagnostics.dart';

/// 所有正文显示器共用的旁路监听，不参加手势竞争，也不请求额外画面。
class ReaderTurnLogging extends StatefulWidget {
  const ReaderTurnLogging({
    super.key,
    required this.details,
    required this.child,
  });
  final Map<String, Object?> details;
  final Widget child;

  @override
  State<ReaderTurnLogging> createState() => _ReaderTurnLoggingState();
}

class _ReaderTurnLoggingState extends State<ReaderTurnLogging> {
  ReaderTurnTrace? _scroll;

  @override
  void initState() {
    super.initState();
    ReaderTurnDiagnostics.arm(this, true);
  }

  void _down(PointerDownEvent event) {
    final view = View.of(context);
    ReaderTurnDiagnostics.pointerDown(event, {
      ...widget.details,
      'orientation': MediaQuery.orientationOf(context).name,
      'dpr': view.devicePixelRatio,
      'refreshRate': view.display.refreshRate,
      'width': context.size?.width,
      'height': context.size?.height,
    });
  }

  void _input(PointerEvent event) {
    ReaderTurnDiagnostics.forPointer(event.pointer)?.input(
      event,
      event is PointerMoveEvent
          ? 'move'
          : event is PointerUpEvent
          ? 'up'
          : 'cancel',
    );
  }

  bool _scrolling(ScrollNotification notification) {
    if (notification.depth != 0) return false;
    if (notification is ScrollStartNotification) {
      _scroll = ReaderTurnDiagnostics.active;
      _scroll?.operationActive = true;
    }
    final trace = _scroll;
    if (trace != null) {
      trace.event('scroll.${notification.runtimeType}', [
        notification.metrics.pixels,
        notification.metrics.viewportDimension,
      ]);
      if (notification is ScrollEndNotification) {
        trace.operationActive = false;
        trace.finish('scrollEnd');
        _scroll = null;
      }
    }
    return false;
  }

  @override
  Widget build(BuildContext context) =>
      NotificationListener<ScrollNotification>(
        onNotification: _scrolling,
        child: Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: _down,
          onPointerMove: _input,
          onPointerUp: _input,
          onPointerCancel: _input,
          child: widget.child,
        ),
      );

  @override
  void dispose() {
    _scroll?.finish('readerDisposed');
    ReaderTurnDiagnostics.arm(this, false);
    super.dispose();
  }
}
