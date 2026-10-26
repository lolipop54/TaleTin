import 'package:flutter/widgets.dart';

import '../../../../core/diagnostics/reader_turn_state_diagnostics.dart';

/// 位于正文和遮挡层外面，区分“触摸到达页面”和“触摸到达翻页控件”。
class ReaderTurnStateBoundary extends StatelessWidget {
  const ReaderTurnStateBoundary({
    super.key,
    required this.details,
    required this.child,
  });
  final Map<String, Object?> details;
  final Widget child;
  @override
  Widget build(BuildContext context) => !readerTurnStateDiagnosticsEnabled
      ? child
      : Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: (event) =>
              ReaderTurnStateDiagnostics.record('reader.pointer.down', {
                ...details,
                'pointer': event.pointer,
                'pointerKind': event.kind.name,
                'x': event.localPosition.dx,
                'y': event.localPosition.dy,
              }),
          onPointerUp: (event) => ReaderTurnStateDiagnostics.record(
            'reader.pointer.up',
            {'pointer': event.pointer},
          ),
          onPointerCancel: (event) => ReaderTurnStateDiagnostics.record(
            'reader.pointer.cancel',
            {'pointer': event.pointer},
          ),
          child: child,
        );
}
