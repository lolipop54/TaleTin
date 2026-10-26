import 'dart:async';

import 'app_errors.dart';

const readerTurnStateDiagnosticsEnabled = bool.fromEnvironment(
  'GT_TRACE_TURN_STATE',
);

/// 旁路记录操作和等待现场；不取消任务，不改变异常、动画或页面交接顺序。
class ReaderTurnStateRecorder {
  ReaderTurnStateRecorder({required this.append, this.nowMs});
  final int Function()? nowMs;
  int get _elapsedMs => nowMs?.call() ?? _clock.elapsedMilliseconds;
  final Future<void> Function(List<Map<String, Object?>>) append;
  final _sources =
      <Object, ({String scope, Map<String, Object?> Function() read})>{};
  final _steps = <int, ({String stage, int beginMs, Set<int> reported})>{};
  final _records = <Map<String, Object?>>[];
  final _clock = Stopwatch()..start();
  final String session = DateTime.now().microsecondsSinceEpoch.toString();
  Timer? _flushTimer, _watchdog;
  int _sequence = 0, _dropped = 0;
  Future<void>? _pendingWrite;

  // 只收集内部数字、开关和枚举；不保存书籍身份、正文、文件路径或原始指令。
  static const _keys = {
    'stepMs',
    'owner',
    'pointer',
    'pointerKind',
    'layout',
    'effect',
    'mode',
    'format',
    'background',
    'backgroundDisposed',
    'controls',
    'panel',
    'selection',
    'note',
    'chapter',
    'page',
    'pages',
    'pageRevision',
    'pageChanged',
    'revisionChanged',
    'effectChanged',
    'mounted',
    'finishing',
    'committing',
    'animating',
    'animation',
    'animationValue',
    'ignored',
    'inputAllowed',
    'dragAccepted',
    'pointerCancelled',
    'direction',
    'offset',
    'dragged',
    'foldReady',
    'foldFutureStored',
    'foldToken',
    'landing',
    'cover',
    'capturing',
    'loading',
    'revealing',
    'opening',
    'checking',
    'completionStored',
    'version',
    'searchBusy',
    'jumpBusy',
    'sourceChanged',
    'settingsReady',
    'titlesReady',
    'displayReady',
    'displayWork',
    'active',
    'failed',
    'generation',
    'priming',
    'restoring',
    'presentTargetStored',
    'presentationStored',
    'held',
    'warmCover',
    'cachedPages',
    'paintedPages',
    'targetPage',
    'targetChapter',
    'knownPage',
    'neighbour',
    'moved',
    'cancelled',
    'status',
    'errorType',
    'x',
    'y',
  };
  static Map<String, Object?> _safe(Map<String, Object?> values) => {
    for (final entry in values.entries)
      if (_keys.contains(entry.key) &&
          (entry.value == null ||
              entry.value is num ||
              entry.value is bool ||
              entry.value is String))
        entry.key: entry.value,
  };

  void attach(
    Object owner,
    String scope,
    Map<String, Object?> Function() read,
  ) {
    _sources[owner] = (scope: scope, read: read);
    record('$scope.attach');
  }

  void detach(Object owner) {
    final source = _sources[owner];
    if (source != null) record('${source.scope}.detach');
    _sources.remove(owner);
  }

  Map<String, Object?> _snapshot() => {
    for (final entry in _sources.entries)
      '${entry.value.scope}:${identityHashCode(entry.key)}': _read(
        entry.value.read,
      ),
  };
  Map<String, Object?> _read(Map<String, Object?> Function() read) {
    try {
      return _safe(read());
    } catch (error) {
      return {'errorType': error.runtimeType.toString()};
    }
  }

  void record(String event, [Map<String, Object?> details = const {}]) {
    if (_records.length >= 128) {
      _dropped++;
      return;
    }
    _records.add({
      'kind': 'readerTurnState',
      'schema': 1,
      'session': session,
      'time': DateTime.now().toIso8601String(),
      'elapsedMs': _elapsedMs,
      'event': event,
      'details': _safe(details),
      if (event.endsWith('pointer.down') ||
          event.contains('step.waiting:') ||
          event.contains('step.error:') ||
          event.startsWith('pageTurn.action') ||
          event == 'pageTurn.widget.reset' ||
          event.startsWith('display.') ||
          event.endsWith('.attach') ||
          event.endsWith('.detach'))
        'states': _snapshot(),
      if (_dropped > 0) 'dropped': _dropped,
    });
    _dropped = 0;
    // 固定的小批次写入，不逐触点移动写盘，也不等待日志写好才执行翻页。
    _flushTimer ??= Timer(const Duration(milliseconds: 400), () {
      _flushTimer = null;
      unawaited(flush());
    });
  }

  Future<T> step<T>(String label, Future<T> Function() action) async {
    // 旧标签可能带桥接参数或章节标识，只保留应用内固定的步骤名前缀。
    final command = RegExp(r'command=(__gt\.[A-Za-z]+)')
        .firstMatch(label)
        ?.group(1);
    final stage = command == null
        ? label
              .split(RegExp(r'[=(#]'))
              .first
              .trim()
              .split(' ')
              .take(2)
              .join(' ')
        : 'web.$command';
    if (_steps.length >= 64) {
      record('step.limit');
      return action();
    }
    final id = ++_sequence;
    final beginMs = _elapsedMs;
    _steps[id] = (stage: stage, beginMs: beginMs, reported: <int>{});
    record('step.begin:$stage:$id');
    _watchdog ??= Timer.periodic(const Duration(seconds: 1), (_) => _waiting());
    try {
      final result = await action();
      record('step.end:$stage:$id', {
        'stepMs': _elapsedMs - beginMs,
        'moved': result is bool ? result : null,
      });
      return result;
    } catch (error) {
      record('step.error:$stage:$id', {
        'stepMs': _elapsedMs - beginMs,
        'errorType': error.runtimeType.toString(),
      });
      rethrow;
    } finally {
      _steps.remove(id);
      if (_steps.isEmpty) {
        _watchdog?.cancel();
        _watchdog = null;
      }
    }
  }

  void _waiting() {
    for (final entry in _steps.entries.toList()) {
      for (final seconds in [2, 10]) {
        if (_elapsedMs - entry.value.beginMs >= seconds * 1000 &&
            entry.value.reported.add(seconds)) {
          record('step.waiting:${entry.value.stage}:${entry.key}:$seconds', {
            'stepMs': _elapsedMs - entry.value.beginMs,
          });
        }
      }
    }
    if (_steps.values.every((step) => step.reported.contains(10))) {
      _watchdog?.cancel();
      _watchdog = null;
    }
  }

  Future<void> flush() async {
    _flushTimer?.cancel();
    _flushTimer = null;
    if (_pendingWrite case final pending?) {
      await pending;
      if (_records.isNotEmpty) await flush();
      return;
    }
    if (_records.isEmpty) return;
    final count = _records.length > 32 ? 32 : _records.length;
    final batch = _records.take(count).toList();
    _records.removeRange(0, count);
    if (_dropped > 0) {
      batch.add({
        'kind': 'readerTurnStateTruncated',
        'session': session,
        'elapsedMs': _elapsedMs,
        'dropped': _dropped,
      });
      _dropped = 0;
    }
    final pending = Future<void>.sync(() => append(batch))
        .catchError((Object _) {});
    _pendingWrite = pending;
    try {
      await pending;
    } finally {
      _pendingWrite = null;
    }
    if (_records.isNotEmpty) await flush();
  }

  void dispose() {
    _watchdog?.cancel();
    _watchdog = null;
    _flushTimer?.cancel();
    _flushTimer = null;
    _sources.clear();
    _steps.clear();
    unawaited(flush());
  }
}

abstract final class ReaderTurnStateDiagnostics {
  static ReaderTurnStateRecorder? _recorder;
  static ReaderTurnStateRecorder get _log =>
      _recorder ??= ReaderTurnStateRecorder(
        append: (records) => AppErrors.store.appendReaderTurnState(records),
      );
  static void attach(
    Object owner,
    String scope,
    Map<String, Object?> Function() read,
  ) {
    if (readerTurnStateDiagnosticsEnabled) _log.attach(owner, scope, read);
  }

  static void detach(Object owner) {
    if (readerTurnStateDiagnosticsEnabled) _recorder?.detach(owner);
  }

  static void record(String event, [Map<String, Object?> details = const {}]) {
    if (readerTurnStateDiagnosticsEnabled) _log.record(event, details);
  }

  static Future<T> step<T>(String label, Future<T> Function() action) =>
      readerTurnStateDiagnosticsEnabled ? _log.step(label, action) : action();
  static Future<void> flush() async {
    await _recorder?.flush();
  }
}
