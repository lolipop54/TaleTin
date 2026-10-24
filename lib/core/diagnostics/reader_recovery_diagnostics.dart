import 'dart:async';

import 'package:flutter/services.dart';

import 'app_errors.dart';

const readerRecoveryDiagnosticsEnabled = bool.fromEnvironment(
  'GT_TRACE_READER_RECOVERY',
);

/// 手动复现回前台后的进度与排版变化。仅诊断包开启，不参与阅读等待链。
abstract final class ReaderRecoveryDiagnostics {
  static const channel = OptionalMethodChannel('gtreader/reader_recovery');
  static final _owners = <Object>{};
  static final _clock = Stopwatch()..start();
  static String _id = '';
  static int _remaining = 0, _until = 0, _sequence = 0;

  static bool get observing =>
      readerRecoveryDiagnosticsEnabled &&
      _owners.isNotEmpty &&
      _remaining > 0 &&
      _clock.elapsedMilliseconds <= _until;

  static void attach(Object owner) {
    if (!readerRecoveryDiagnosticsEnabled || !_owners.add(owner)) return;
    _id = '${DateTime.now().microsecondsSinceEpoch}-${++_sequence}';
    resume();
    channel.setMethodCallHandler((call) async {
      if (call.method == 'native' && call.arguments is Map) {
        record('native', Map<String, Object?>.from(call.arguments as Map));
      }
    });
    unawaited(_native('watch', true));
  }

  static void resume() {
    if (!readerRecoveryDiagnosticsEnabled) return;
    _remaining = 1000;
    _until = _clock.elapsedMilliseconds + 60000;
  }

  static void detach(Object owner) {
    if (!readerRecoveryDiagnosticsEnabled || !_owners.remove(owner)) return;
    if (_owners.isEmpty) {
      unawaited(_native('watch', false));
      channel.setMethodCallHandler(null);
    }
  }

  static void nativeSnapshot(String reason) {
    if (!observing) return;
    unawaited(_native('snapshot', reason));
  }

  static Future<void> _native(String method, Object argument) async {
    try {
      await channel.invokeMethod<void>(method, argument);
    } catch (_) {
      // 诊断失败不能改变显示、位置保存或错误提示。
    }
  }

  static void record(String event, Map<String, Object?> details) {
    if (!observing) return;
    _remaining--;
    unawaited(
      Future<void>.sync(
        () => AppErrors.store.appendReaderRecovery({
          'kind': 'readerRecovery',
          'schema': 1,
          'id': _id,
          'time': DateTime.now().toIso8601String(),
          'elapsedMs': _clock.elapsedMilliseconds,
          'event': event,
          'details': details,
        }),
      ).catchError((Object _) {}),
    );
  }

  /// 网页原始事件可能含正文和DOM路径，只拣选诊断所需数字及状态。
  static Map<String, Object?> webFields(Map<String, Object?> raw) => {
    for (final key in const [
      'type',
      'event',
      'ms',
      'page',
      'pages',
      'knownPages',
      'indexComplete',
      'fraction',
      'width',
      'height',
      'innerWidth',
      'innerHeight',
      'columnWidth',
      'margin',
      'contentWidth',
      'scrollWidth',
      'visibility',
    ])
      if (raw[key] case final Object value)
        if (value is num ||
            value is bool ||
            (value is String &&
                const ['type', 'event', 'visibility'].contains(key)))
          key: value,
  };
}
