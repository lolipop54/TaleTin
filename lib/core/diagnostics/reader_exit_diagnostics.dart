import 'dart:async';
import 'dart:developer' as developer;

import 'app_errors.dart';

/// 普通包也保留退出现场。仅观察，不超时退出、不改变保存或路由顺序。
class ReaderExitDiagnostics {
  ReaderExitDiagnostics(
    this.scope, {
    Map<String, Object?> details = const {},
    Future<void> Function(Map<String, Object?>)? append,
  }) : _append = append ?? AppErrors.store.appendReaderExit,
       id = '${DateTime.now().microsecondsSinceEpoch}-${++_sequence}',
       context = {
         for (final key in _contextKeys)
           if (details.containsKey(key)) key: details[key],
       } {
    _record('begin');
    _waiting = Timer(const Duration(seconds: 2), () => _record('waiting'));
  }

  static int _sequence = 0;
  static const _contextKeys = [
    'layout',
    'turnEffect',
    'controls',
    'panel',
    'scrolling',
  ];
  static bool covers(String scope) =>
      scope.startsWith('reader.exit.') || scope == 'reader.body.dispose';

  final String scope, id;
  final Map<String, Object?> context;
  final Future<void> Function(Map<String, Object?>) _append;
  final _clock = Stopwatch()..start();
  late final Timer _waiting;
  bool _finished = false;

  void finish(String status) {
    if (_finished) return;
    _finished = true;
    _waiting.cancel();
    _record('end', status: status);
  }

  void _record(String event, {String? status}) {
    final record = <String, Object?>{
      'kind': 'readerExit',
      'id': id,
      'scope': scope,
      'event': event,
      'time': DateTime.now().toIso8601String(),
      'elapsedMs': _clock.elapsedMilliseconds,
      'context': context,
      'status': ?status,
    };
    // 诊断磁盘写入不加入退出的等待链；失败也不能递归报告或弹 Toast。
    unawaited(
      Future<void>.sync(() => _append(record)).catchError(
        (Object error) =>
            developer.log('退出诊断写入失败：$error', name: 'TaleTin.diagnostic'),
      ),
    );
  }
}
