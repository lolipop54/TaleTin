part of 'original_host_controller.dart';

/// 合并同一显示帧内的位移；跨桥返回较快时也不重复下发中间位置。
extension OriginalDragDelivery on OriginalHostController {
  int? get diagnosticViewId => _webView?.getViewId() as int?;

  void beginTurnDiagnostics(ReaderTurnTrace trace) {
    _turnDiagnosticTrace = trace;
    trace.browserSources['${identityHashCode(this)}'] = () => _evaluate(
      source:
          'JSON.stringify(window.gtReaderTurnDiagnostics?.take(${jsonEncode(trace.id)}) ?? null)',
    );
  }

  void endTurnDiagnostics(ReaderTurnTrace trace) {
    if (identical(_turnDiagnosticTrace, trace)) _turnDiagnosticTrace = null;
  }

  Future<void> drag(double dx) {
    _turnDiagnosticTrace?.event('drag.queue', [
      dx,
      _dragFlight != null,
      _dragEnding,
    ]);
    if (_dragEnding) return _dragFlight ?? Future<void>.value();
    if (readerPerformanceEnabled) _dragInputs++;
    _pendingDrag = dx;
    final idle = _dragIdle ??= Completer<void>();
    if (_dragFlight == null && _dragFrameCallback == null) {
      _deliverLatestDrag();
    }
    return idle.future;
  }

  void _deliverLatestDrag() {
    // 在途调用可能跨过显示帧。若新帧已经开始，马上补发最新位置；
    // 不能无条件再等下一帧，否则一次慢桥接会额外漏掉一个刷新周期。
    // 同帧仍只发一次，使用系统帧时钟，不受动画时间缩放影响。
    if (_lastDragFrame !=
        SchedulerBinding.instance.currentSystemFrameTimeStamp) {
      _dragFlight = _sendDrag();
    } else {
      _scheduleDrag();
    }
  }

  void _scheduleDrag() {
    if (_dragFrameCallback != null || _pendingDrag == null || _dragEnding) {
      return;
    }
    _dragFrameCallback = SchedulerBinding.instance.scheduleFrameCallback((_) {
      _turnDiagnosticTrace?.event('drag.frame', [
        SchedulerBinding.instance.currentSystemFrameTimeStamp.inMicroseconds,
      ]);
      _dragFrameCallback = null;
      if (_pendingDrag != null && !_dragEnding) _dragFlight = _sendDrag();
    });
  }

  Future<void> _sendDrag() async {
    final dx = _pendingDrag!;
    _pendingDrag = null;
    _lastDragFrame = SchedulerBinding.instance.currentSystemFrameTimeStamp;
    _turnDiagnosticTrace?.event('drag.send', [dx]);
    final watch = readerPerformanceEnabled ? (Stopwatch()..start()) : null;
    try {
      await _call('__gt.drag(${dx.round()})');
      if (watch != null) {
        final us = watch.elapsedMicroseconds;
        _dragCalls++;
        _dragTotalUs += us;
        if (us > _dragMaxUs) _dragMaxUs = us;
      }
    } finally {
      _dragFlight = null;
      if (_pendingDrag != null && !_dragEnding) {
        _deliverLatestDrag();
      } else {
        _finishDragBatch();
      }
    }
  }

  void _finishDragBatch() {
    final idle = _dragIdle;
    _dragIdle = null;
    if (idle != null && !idle.isCompleted) idle.complete();
  }

  /// 松手取消未发送的位置；在途写入结束后才启动既有网页收尾动画。
  Future<void> settle(int pageDelta) async {
    _turnDiagnosticTrace?.event('settle.begin', [
      pageDelta,
      _dragFlight != null,
    ]);
    _dragEnding = true;
    _pendingDrag = null;
    final callback = _dragFrameCallback;
    if (callback != null) {
      SchedulerBinding.instance.cancelFrameCallbackWithId(callback);
    }
    _dragFrameCallback = null;
    try {
      await _dragFlight;
      _finishDragBatch();
      if (readerPerformanceEnabled && _dragInputs > 0) {
        readerPerf('original.slide.dragBridge', _dragTotalUs, {
          'inputs': _dragInputs,
          'calls': _dragCalls,
          'maxUs': _dragMaxUs,
        });
        _dragInputs = _dragCalls = _dragTotalUs = _dragMaxUs = 0;
      }
      await _call('__gt.settle($pageDelta)');
      _turnDiagnosticTrace?.event('settle.return');
    } finally {
      _dragEnding = false;
      _lastDragFrame = null;
    }
  }
}
