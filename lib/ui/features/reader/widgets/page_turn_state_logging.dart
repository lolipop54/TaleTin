part of 'page_turn_area.dart';

extension _PageTurnStateLogging on _PageTurnAreaState {
  Map<String, Object?> _stallState() => {
    'mounted': mounted,
    'mode': widget.traceLabel,
    'effect': widget.effect.name,
    'pageRevision': _stallPageRevision,
    'pointer': _pointer,
    'finishing': _finishingInput,
    'committing': _committing,
    'animating': _controller.isAnimating,
    'animation': _controller.status.name,
    'animationValue': _controller.value,
    'ignored': _ignorePointer,
    'dragAccepted': _dragAccepted,
    'pointerCancelled': _pointerCancelled,
    'direction': _direction?.name,
    'offset': _offset,
    'dragged': _dragged,
    'foldReady': _fold != null,
    'foldFutureStored': _foldPending != null,
    'foldToken': _foldToken,
    'landing': _landing != null,
    'neighbour': _neighbour != null,
  };
  void _stallEvent(String event, [Map<String, Object?> details = const {}]) {
    if (readerTurnStateDiagnosticsEnabled) {
      ReaderTurnStateDiagnostics.record('pageTurn.$event', {
        'owner': identityHashCode(this),
        ...details,
      });
    }
  }
}
