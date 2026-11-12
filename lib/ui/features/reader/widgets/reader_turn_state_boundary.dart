import 'package:flutter/widgets.dart';

import '../../../../core/diagnostics/reader_turn_state_diagnostics.dart';

/// 位于正文和遮挡层外面，区分“触摸到达页面”和“触摸到达翻页控件”。
class ReaderTurnStateBoundary extends StatelessWidget {
  const ReaderTurnStateBoundary({
    super.key,
    required this.details,
    required this.observeStalls,
    required this.child,
  });
  final Map<String, Object?> details;
  final bool observeStalls;
  final Widget child;

  void _onPointerDown(PointerDownEvent event) {
    ReaderTurnStateDiagnostics.record('reader.pointer.down', {
      ...details,
      'pointer': event.pointer,
      'pointerKind': event.kind.name,
      if (readerTurnStateDiagnosticsEnabled) ...{
        'x': event.localPosition.dx,
        'y': event.localPosition.dy,
      },
    });
    if (!readerTurnStateDiagnosticsEnabled) {
      ReaderTurnStateDiagnostics.outerPointerDown(
        event.pointer,
        expectsPage:
            details['settingsReady'] == true &&
            details['sourceChanged'] == false &&
            details['controls'] == false &&
            details['panel'] == 'none' &&
            details['selection'] == false &&
            details['note'] == false,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final observing =
        readerTurnStateDiagnosticsEnabled ||
        observeStalls && ReaderTurnStateDiagnostics.enabled;
    // 切换翻页方式只改变监听。保留子树才能用原正文截图完成显示交接。
    return Listener(
      behavior: observing
          ? HitTestBehavior.translucent
          : HitTestBehavior.deferToChild,
      onPointerDown: observing ? _onPointerDown : null,
      onPointerUp: observing
          ? (event) => ReaderTurnStateDiagnostics.record('reader.pointer.up', {
              'pointer': event.pointer,
            })
          : null,
      onPointerCancel: observing
          ? (event) => ReaderTurnStateDiagnostics.record(
              'reader.pointer.cancel',
              {'pointer': event.pointer},
            )
          : null,
      child: child,
    );
  }
}
