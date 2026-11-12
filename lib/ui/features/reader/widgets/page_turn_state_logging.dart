part of 'page_turn_area.dart';

extension _PageTurnStateLogging on _PageTurnAreaState {
  bool get _observeStalls => widget.traceLabel == 'simplified';

  Future<T> _tracePageStep<T>(String label, Future<T> Function() action) =>
      traceTurnStep(label, action, observeStalls: _observeStalls, owner: this);

  Map<String, Object?> _stallState() => {
    'mounted': mounted,
    'mode': widget.traceLabel,
    'effect': widget.effect.name,
    'spread': widget.spread,
    'pageRevision': _stallPageRevision,
    'pointer': _pointer,
    'finishing': _finishingInput,
    'committing': _committing,
    'animating': _controller.isAnimating,
    'animation': _controller.status.name,
    'animationValue': _controller.value,
    'ignored': _ignorePointer,
    'inputAllowed': widget.inputAllowed?.call(),
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
    if (readerTurnStateDiagnosticsEnabled ||
        _observeStalls && ReaderTurnStateDiagnostics.enabled) {
      ReaderTurnStateDiagnostics.record('pageTurn.$event', {
        'owner': identityHashCode(this),
        'pageRevision': _stallPageRevision,
        if (event == 'action.end') 'committing': _committing,
        ...details,
      });
    }
  }

  void _observePointerDown(int pointer, String? blockReason) {
    if (!_observeStalls || !ReaderTurnStateDiagnostics.enabled) return;
    ReaderTurnStateDiagnostics.pagePointerDown(pointer);
    if (blockReason == null) {
      _blockedInputCheck?.cancel();
      _blockedInputCheck = null;
      _reportedBlockedInput = false;
    } else if (!_reportedBlockedInput) {
      // 短暂挡住连点是正常交接。两秒后仍挡住才保留现场。
      _blockedInputCheck ??= Timer(const Duration(seconds: 2), () {
        _blockedInputCheck = null;
        if (!mounted) return;
        try {
          final stillBlocked = _inputBlockReason();
          if (stillBlocked == null) return;
          _reportedBlockedInput = true;
          ReaderTurnStateDiagnostics.blockedInput({
            'owner': identityHashCode(this),
            'pointer': pointer,
            'blockReason': stillBlocked,
          });
        } catch (_) {
          // 延后的诊断读取失败不影响手势。
        }
      });
    }
  }
}
