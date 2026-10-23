import 'dart:convert';
import 'dart:developer' show Timeline;
import 'dart:isolate';

import 'reader_exit_diagnostics.dart';
import 'reader_turn_diagnostics.dart';

const readerWorkTraceEnabled = bool.fromEnvironment('GT_TRACE_READER_PERF');
int _sequence = 0;

/// Follow one actual user open from the shelf tap through the loading-layer
/// removal. Phase logs can be joined to this record by book ID and wall time.
abstract final class BookOpeningTrace {
  static final _active = <String, ReaderWorkTrace>{};
  static bool get isActive => _active.isNotEmpty;
  static void begin(
    String bookId, {
    String entry = 'route',
    Map<String, Object?> details = const {},
  }) {
    if (!readerWorkTraceEnabled) return;
    if (entry == 'route' && _active.containsKey(bookId)) return;
    _active.remove(bookId)?.finish(status: 'replaced');
    _active[bookId] = ReaderWorkTrace.start('book.open.total', {
      'bookId': bookId,
      'entry': entry,
      ...details,
    })!;
  }

  static void mark(String bookId, String phase) {
    if (readerWorkTraceEnabled) _active[bookId]?.mark(phase);
  }

  static void finish(String bookId, {String status = 'ok'}) {
    if (readerWorkTraceEnabled) _active.remove(bookId)?.finish(status: status);
  }
}

Future<T> traceReaderWork<T>(
  String scope,
  Future<T> Function() action, [
  Map<String, Object?> details = const {},
]) async {
  if (!readerWorkTraceEnabled && !ReaderExitDiagnostics.covers(scope) &&
      ReaderTurnDiagnostics.active == null) {
    return action();
  }
  final trace = ReaderWorkTrace.start(scope, details);
  try {
    final result = await action();
    trace?.finish();
    return result;
  } catch (error) {
    trace?.finish(status: error.runtimeType.toString());
    rethrow;
  }
}

/// 只记录任务编号、数量和耗时。Data／引擎可直接使用，不依赖界面或平台通道。
/// begin/end 可以找出未返回的任务；细分耗时随 end 一次输出，避免逐块刷日志。
class ReaderWorkTrace {
  ReaderWorkTrace._(this.scope, this.details)
    : id = '${Isolate.current.hashCode}:${++_sequence}',
      _clock = Stopwatch()..start() {
    _exit = ReaderExitDiagnostics.covers(scope)
        ? ReaderExitDiagnostics(scope, details: details)
        : null;
    _emit('begin');
  }

  static ReaderWorkTrace? start(
    String scope, [
    Map<String, Object?> details = const {},
  ]) => readerWorkTraceEnabled || ReaderExitDiagnostics.covers(scope) ||
        ReaderTurnDiagnostics.active != null
      ? ReaderWorkTrace._(scope, {...details})
      : null;

  final String scope, id;
  final Map<String, Object?> details;
  final Stopwatch _clock;
  final _turn = ReaderTurnDiagnostics.active;
  late final ReaderExitDiagnostics? _exit;
  final _stages = <String, int>{};
  var _mark = 0;
  var _finished = false;

  void mark(String stage) {
    final now = _clock.elapsedMicroseconds;
    _stages[stage] = (_stages[stage] ?? 0) + now - _mark;
    _mark = now;
  }

  void finish({String status = 'ok'}) {
    if (_finished) return;
    _finished = true;
    _exit?.finish(status);
    mark('remaining');
    _emit('end', status: status);
  }

  void _emit(String event, {String? status}) {
    _turn?.event('work.$scope.$event', [
      _clock.elapsedMicroseconds,
      ?status,
      for (final entry in details.entries)
        if (entry.value is num || entry.value is bool) [entry.key, entry.value],
      for (final entry in _stages.entries) [entry.key, entry.value],
    ]);
    if (!readerWorkTraceEnabled) return;
    // 输出原始事件时间，不能用 logcat 接收／节流刷新时间计算翻页延迟。
    // ignore: avoid_print
    print(
      'GT_READER_WORK ${jsonEncode({
        'event': event,
        'id': id,
        'scope': scope,
        'wallUs': DateTime.now().microsecondsSinceEpoch,
        'atUs': Timeline.now,
        ...details,
        if (status != null) ...{'status': status, 'totalUs': _clock.elapsedMicroseconds, 'stagesUs': _stages},
      })}',
    );
  }
}
