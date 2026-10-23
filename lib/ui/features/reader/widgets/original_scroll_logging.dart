part of 'original_scroll_area.dart';

/// 复用原有180ms位置回报和settled消息，不额外逐帧跨桥查询滚动位置。
extension _OriginalScrollLogging on OriginalScrollAreaState {
  void _traceScrollDown(PointerDownEvent event) {
    _scrollLog?.finish('scrollInterruptedByInput');
    final controller = host;
    final trace = ReaderTurnDiagnostics.pointerDown(event, {
      'layout': 'original',
      'effect': 'scroll',
      'chapter': widget.session.chapterIndex,
    }, controller?.getViewId() as int?);
    _scrollLog = trace;
    if (trace == null || controller == null) return;
    final token = identityHashCode(controller);
    trace.browserSources['$token'] = () => controller.evaluateJavascript(
      source:
          'JSON.stringify(window.gtReaderTurnDiagnostics?.take(${jsonEncode(trace.id)}) ?? null)',
    );
    // 只在起手时启动网页观察器；不改变原来的滚动、加载或触摸处理。
    unawaited(() async {
      final sequence = trace.commandBegin(
        'diagnostics.observeScroll',
        hostToken: token,
      );
      try {
        await controller.evaluateJavascript(
          source:
              'window.gtReaderTurnDiagnostics?.run(${jsonEncode(trace.id)},$sequence,function(){})',
        );
      } catch (error) {
        trace.event('scroll.observerUnavailable', [
          error.runtimeType.toString(),
        ]);
      } finally {
        trace.commandEnd(sequence);
      }
    }());
  }

  Future<Object?> _tracedScrollMessage(Map<String, dynamic> raw) async {
    final trace = _scrollLog;
    final type = raw['type'];
    if (trace != null &&
        trace.endUs == null &&
        (type == 'position' || type == 'settled')) {
      trace.operationActive = true;
      trace.event('scroll.$type');
    }
    try {
      return await _message(raw);
    } finally {
      if (type == 'settled' && trace != null) {
        trace.operationActive = false;
        trace.finish('scrollSettled');
      }
    }
  }
}
