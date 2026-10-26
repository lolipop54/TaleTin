part of 'page_turn_area.dart';

extension _PageTurnInput on _PageTurnAreaState {
  String get _traceInput =>
      'pointer=$_pointer active=${_responseTrace.active} mode=${widget.traceLabel} '
      'turn=${widget.turnId} effect=${widget.effect.name} ignore=$_ignorePointer '
      'accepted=$_dragAccepted busy=$_finishingInput/$_committing token=$_foldToken';

  void _tracePointer(PointerEvent event) {
    if (!turnTraceEnabled) return;
    traceTurnSample('raw-${event.pointer}', [
      event.runtimeType.toString(),
      event.timeStamp.inMicroseconds,
      event.position.dx,
      event.position.dy,
      event.localPosition.dx,
      event.localPosition.dy,
      event.delta.dx,
      event.delta.dy,
    ]);
    if (event is PointerUpEvent || event is PointerCancelEvent) {
      traceTurnFlush('raw-${event.pointer}');
      traceTurnFlush('drag-${event.pointer}');
      traceTurn(
        'pointer end $_traceInput cancelled=${event is PointerCancelEvent}',
      );
    }
  }

  Widget _buildInput(double width) => Listener(
    onPointerDown: (event) {
      _tracePointer(event);
      _pointer = event.pointer;
      _responseTrace.begin(event.pointer, event.timeStamp);
      // 按下时决定整轮是否接收。忙碌中起手即使拖到空闲，也不能半途接管。
      _ignorePointer =
          _finishingInput ||
          _committing ||
          _controller.isAnimating ||
          !(widget.inputAllowed?.call() ?? true);
      _logPointerDown(event);
      _stallEvent('pointer.down', {'pointer': event.pointer});
      traceTurn('down $_traceInput animating=${_controller.isAnimating}');
      if (_ignorePointer) {
        readerPerf('${widget.traceLabel}.${widget.effect.name}.ignored', 0);
        return;
      }
      _pointerCancelled = false;
      if (_needsDragFrames) _dragFrames.motion();
      _responseTrace.activate(_pointer);
      widget.onInteractionStart?.call();
    },
    onPointerMove: (event) {
      if (!_ignorePointer && _needsDragFrames) _dragFrames.motion();
      _responseTrace.move(event.pointer, event.timeStamp);
      _tracePointer(event);
    },
    onPointerUp: (event) {
      _dragFrames.stop();
      _tracePointer(event);
      _stallEvent('pointer.up', {'pointer': event.pointer});
    },
    onPointerCancel: (event) {
      _dragFrames.stop();
      _tracePointer(event);
      _stallEvent('pointer.cancel', {'pointer': event.pointer});
      if (!_ignorePointer) _pointerCancelled = true;
    },
    child: ReaderDragDetector(
      onTapUp: (details) {
        _stallEvent('gesture.tap');
        if (!_ignorePointer) _turnLog?.event('gesture.tap');
        if (!_ignorePointer) _finishInput(() => _onTapUp(details, width));
      },
      onHorizontalDragStart: (details) {
        _stallEvent('gesture.drag.start');
        if (!_ignorePointer) {
          _turnLog?.operationActive = true;
          _turnLog?.event('gesture.drag');
        }
        _responseTrace.recognized(_pointer);
        traceTurn('recognizer start $_traceInput');
        if (!_ignorePointer) _onDragStart(details);
      },
      onHorizontalDragUpdate: (details) {
        if (!_ignorePointer) _logDrag(details);
        if (turnTraceEnabled) {
          traceTurnSample('drag-$_pointer', [
            details.sourceTimeStamp?.inMicroseconds,
            details.localPosition.dx,
            details.localPosition.dy,
            details.delta.dx,
            details.delta.dy,
            _ignorePointer,
            _dragAccepted,
          ]);
        }
        if (!_ignorePointer) _onDragUpdate(details, width);
      },
      onHorizontalDragEnd: (details) {
        _stallEvent('gesture.drag.end');
        traceTurnFlush('drag-$_pointer');
        traceTurn('recognizer end $_traceInput distance=$_dragged');
        if (!_ignorePointer && _dragAccepted) {
          _finishInput(() => _onDragEnd(details, width));
        }
      },
      onHorizontalDragCancel: () {
        _stallEvent('gesture.drag.cancel');
        traceTurnFlush('drag-$_pointer');
        traceTurn('recognizer cancel $_traceInput');
        if (!_ignorePointer && _dragAccepted) {
          _finishInput(() => _onDragCancel(width));
        }
      },
      child: ClipRect(
        child: ValueListenableBuilder<int>(
          valueListenable: _motion,
          builder: (context, value, child) => _buildStack(width),
        ),
      ),
    ),
  );
}
