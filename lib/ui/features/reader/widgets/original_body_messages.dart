part of 'original_body.dart';

/// 网页消息接收与加载编号核对；诊断只挑选状态，不改变消息处理顺序。
extension _OriginalBodyMessages on _OriginalBodyState {
  Object? _onHostMessage(List<dynamic> args) {
    if (args.isEmpty || args.first is! String) return null;
    final envelope = (jsonDecode(args.first as String) as Map)
        .cast<String, Object?>();
    final event = (envelope['event'] as Map).cast<String, Object?>();
    final matches = _frames.where(
      (frame) =>
          frame.slot == envelope['slot'] &&
          frame.load == envelope['load'] &&
          frame.chapter.ordinal == envelope['chapter'],
    );
    if (ReaderRecoveryDiagnostics.observing &&
        const {
          'recovery',
          'ready',
          'paginated',
          'relocate',
          'page',
          'indexReady',
          'preparing',
          'boundary',
        }.contains(event['type'])) {
      ReaderRecoveryDiagnostics.record('webMessage', {
        ...ReaderRecoveryDiagnostics.webFields(event),
        'slot': envelope['slot'],
        'load': envelope['load'],
        'chapter': envelope['chapter'],
        'currentChapter': widget.current,
        'acceptedEnvelope': mounted && matches.isNotEmpty,
      });
    }
    if (!mounted || matches.isEmpty) return null;
    final frame = matches.first;
    if (bookmarkTraceEnabled &&
        const {
          'bookmarkTrace',
          'ready',
          'paginated',
          'relocate',
          'page',
        }.contains(event['type'])) {
      traceBookmark('web-event', {
        'chapter': frame.chapter.ordinal,
        'slot': frame.slot,
        'load': frame.load,
        'host': identityHashCode(frame.host),
        'currentChapter': widget.current,
        if (event['type'] == 'bookmarkTrace')
          ...event
        else ...{
          for (final key in [
            'type',
            'page',
            'pages',
            'fraction',
            'width',
            'step',
            'columnWidth',
            'contentWidth',
            'scrollWidth',
          ])
            if (event.containsKey(key)) key: event[key],
          'bookmarkPages': frame.host.bookmarkPages,
        },
      });
    }
    traceTurn(
      'body event chapter=${frame.chapter.ordinal} slot=${frame.slot} load=${frame.load} web=${_controller?.getViewId()} type=${event['type']} page=${event['page']} pages=${event['pages']} stage=${event['stage']} jsMs=${event['ms']} elapsedMs=${event['elapsedMs']}'
      '${event['stage'] == 'startup-command' || event['stage'] == 'startup-frame' ? ' detail=${jsonEncode(event)}' : ''}',
    );
    if (event['type'] == 'paginated') {
      frame.paginated = true;
      if (event['deferredImagePixels'] case final bool deferred) {
        frame.host.deferredImagePixels = deferred;
      }
    }
    if (event['type'] == 'ready' && !frame.started) {
      frame.readyWidth = (event['width'] as num?)?.toDouble() ?? _width;
      _syncChapters();
    }
    frame.chapter.onHostEvent?.call(event);
    return null;
  }
}
