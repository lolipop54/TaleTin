part of 'original_reader_area.dart';

/// 旁路观察原书分页；不等待日志、不改手势识别、预载或落页顺序。
extension _ReaderTurnLogging on _OriginalReaderAreaState {
  void _readingPointerDown(PointerDownEvent event) {
    _plainIgnorePointer = _plainBusy;
    _turnPointerDown(event);
    if (_plainIgnorePointer) {
      readerPerf('original.${widget.settings.pageTurnEffect.name}.ignored', 0);
    }
    _preload.hold(event.pointer);
  }

  void _readingPointerUp(PointerUpEvent event) {
    _turnPointerUp(event);
    _preload.release(event.pointer);
  }

  void _readingPointerCancel(PointerCancelEvent event) {
    _turnPointerUp(event, cancel: true);
    _preload.release(event.pointer);
  }

  void _configureTurnLogging() => ReaderTurnDiagnostics.arm(this, true);

  void _turnPointerDown(PointerDownEvent event) {
    if (!readerTurnDiagnosticsEnabled) {
      return;
    }
    final settings = widget.settings;
    final view = View.of(context);
    final trace = ReaderTurnDiagnostics.pointerDown(event, {
      'layout': 'original',
      'effect': settings.pageTurnEffect.name,
      'bookEdges': settings.bookEdges,
      'fontFamily': settings.fontFamily,
      'fontSize': settings.fontSize,
      'fontWeight': settings.fontWeight,
      'lineHeight': settings.lineHeight,
      'paragraphGapEm': settings.paragraphGapEm,
      'useOriginalFont': settings.useOriginalFont,
      'orientation': MediaQuery.orientationOf(context).name,
      'dpr': view.devicePixelRatio,
      'refreshRate': view.display.refreshRate,
      'width': _submittedPageWidth,
      'hostWidth': _submittedPageWidth,
      'height': context.size?.height,
      'chapter': widget.session.chapterIndex,
      'page': _page,
      'pages': _pageCount,
      'edge': _edge,
      'busy': _plainBusy,
      'ignored': _plainIgnorePointer,
      'landing': _landing,
      'handover': _handoverTarget != null,
      'hostReady': _host?.hasReadableWindow == true,
    }, _host?.diagnosticViewId);
    if (_plainIgnorePointer) {
      trace?.finish('ignoredBusy');
    } else if (trace != null) {
      _turnLog = trace;
      for (final host in _hosts.values) {
        host.beginTurnDiagnostics(trace);
      }
    }
  }

  void _turnPointerMove(PointerMoveEvent event) =>
      _turnLog?.input(event, 'move');

  void _turnPointerUp(PointerEvent event, {bool cancel = false}) {
    _turnLog?.input(event, cancel ? 'cancel' : 'up');
  }

  void _finishTurnLog(ReaderTurnTrace? trace, String status) {
    if (trace == null) return;
    trace.finish(status);
    for (final host in _hosts.values) {
      host.endTurnDiagnostics(trace);
    }
    if (identical(_turnLog, trace)) _turnLog = null;
  }
}
