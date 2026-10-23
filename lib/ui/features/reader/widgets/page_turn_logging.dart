part of 'page_turn_area.dart';

extension _PageTurnLogging on _PageTurnAreaState {
  void _logPointerDown(PointerDownEvent event) {
    final trace = ReaderTurnDiagnostics.pointerDown(event, {
      'effect': widget.effect.name,
      'pageWidth': (context.size?.width ?? 0) / (widget.spread ? 2 : 1),
      'pageHeight': context.size?.height,
      'busy': _finishingInput || _committing || _controller.isAnimating,
      'ignored': _ignorePointer,
    });
    if (_ignorePointer) {
      trace?.finish('ignoredBusy');
    } else {
      _turnLog = trace;
    }
  }

  void _logDrag(DragUpdateDetails details) => _turnLog?.event('drag.update', [
    details.sourceTimeStamp?.inMicroseconds ?? -1,
    details.localPosition.dx,
    details.localPosition.dy,
    _offset,
    _dragged,
    _fold != null,
    _foldPending != null,
  ]);
}
