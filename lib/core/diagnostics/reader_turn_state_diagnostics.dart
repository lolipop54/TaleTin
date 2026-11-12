import 'dart:async';
import 'dart:collection';
import 'dart:io';

import '../../engine/layout/chapter_layout.dart' show LayoutCancelled;
import 'app_errors.dart';

const readerTurnStateDiagnosticsEnabled = bool.fromEnvironment(
  'GT_TRACE_TURN_STATE',
);

/// 旁路记录操作和等待现场；不取消任务，不改变异常、动画或页面交接顺序。
class ReaderTurnStateRecorder {
  ReaderTurnStateRecorder({
    required this.append,
    this.nowMs,
    this.incidentsOnly = false,
  });
  final int Function()? nowMs;
  final bool incidentsOnly;
  int get _elapsedMs => nowMs?.call() ?? _clock.elapsedMilliseconds;
  final Future<void> Function(List<Map<String, Object?>>) append;
  final _sources =
      <Object, ({String scope, Map<String, Object?> Function() read})>{};
  final _steps =
      <int, ({String stage, int beginMs, Set<int> reported, Object? owner})>{};
  final _records = <Map<String, Object?>>[];
  final _recent = Queue<Map<String, Object?>>();
  final _clock = Stopwatch()..start();
  final String session = DateTime.now().microsecondsSinceEpoch.toString();
  Timer? _flushTimer, _watchdog;
  int _sequence = 0, _dropped = 0;
  int? _lastPagePointer, _outerOnlySince;
  final _lastIncident = <String, int>{};
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
    'blockReason',
    'spread',
    'moving',
    'displayedPage',
    'pageMatches',
    'viewportMatches',
    'materialsReady',
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
    'cancelReason',
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
    if (scope == 'pageTurn') _outerOnlySince = null;
    record('$scope.attach');
  }

  void detach(Object owner) {
    final source = _sources[owner];
    if (source != null) record('${source.scope}.detach');
    _sources.remove(owner);
    if (incidentsOnly) {
      // 离开阅读页后，旧等待不能再采集另一次阅读的画面状态。
      _steps.removeWhere((_, step) => identical(step.owner, owner));
      _stopIdleWatchdog();
    }
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
    final snapshot =
        !incidentsOnly &&
        (event.endsWith('pointer.down') ||
            event.contains('step.waiting:') ||
            event.contains('step.error:') ||
            event.startsWith('pageTurn.action') ||
            event == 'pageTurn.widget.reset' ||
            event.startsWith('display.') ||
            event.endsWith('.attach') ||
            event.endsWith('.detach'));
    final entry = _entry(event, details, snapshot: snapshot);
    if (incidentsOnly) {
      // 普通翻页只保留最近的步骤，不做快照，也不触发磁盘写入。
      if (_recent.length == 64) _recent.removeFirst();
      _recent.addLast(entry);
    } else {
      _enqueue(entry);
    }
  }

  void incident(
    String event,
    Map<String, Object?> details, {
    String? throttleKey,
  }) {
    if (!incidentsOnly) {
      record(event, details);
      return;
    }
    if (throttleKey != null) {
      final now = _elapsedMs;
      final previous = _lastIncident[throttleKey];
      if (previous != null && now - previous < 2000) {
        record(event, details);
        return;
      }
      _lastIncident[throttleKey] = now;
    }
    for (final entry in _recent) {
      _enqueue(entry);
    }
    _recent.clear();
    // 等待落盘的旧批次满额时仍保留新现场。
    if (_records.length == 128) {
      _records.removeAt(0);
      _dropped++;
    }
    _enqueue(_entry(event, details, snapshot: true));
  }

  void pagePointerDown(int pointer) {
    _lastPagePointer = pointer;
    _outerOnlySince = null;
  }

  void outerPointerDown(int pointer, {required bool expectsPage}) {
    if (!incidentsOnly) return;
    // Flutter 沿命中路径先分发给内层，使用同一 pointer 核对两处监听。
    if (!expectsPage || _lastPagePointer == pointer) {
      _outerOnlySince = null;
      return;
    }
    final now = _elapsedMs;
    final since = _outerOnlySince ??= now;
    if (now - since >= 2000) {
      _outerOnlySince = now;
      incident('reader.pointer.missedPageTurn', {
        'pointer': pointer,
        'stepMs': now - since,
      }, throttleKey: 'missedPageTurn');
    }
  }

  Map<String, Object?> _entry(
    String event,
    Map<String, Object?> details, {
    required bool snapshot,
  }) => {
    'kind': 'readerTurnState',
    'schema': 1,
    'session': session,
    'time': DateTime.now().toIso8601String(),
    'elapsedMs': _elapsedMs,
    'event': event,
    'details': _safe(details),
    if (snapshot) 'states': _snapshot(),
  };

  void _enqueue(Map<String, Object?> entry) {
    if (_records.length >= 128) {
      _dropped++;
      return;
    }
    _records.add(entry);
    // 固定的小批次写入，不逐触点移动写盘，也不等待日志写好才执行翻页。
    _flushTimer ??= Timer(const Duration(milliseconds: 400), () {
      _flushTimer = null;
      unawaited(flush());
    });
  }

  static final _webCommand = RegExp(r'command=(__gt\.[A-Za-z]+)');
  static final _labelEnd = RegExp(r'[=(#]');

  Future<T> step<T>(
    String label,
    Future<T> Function() action, {
    Object? owner,
  }) async {
    if (incidentsOnly && owner != null && !_sources.containsKey(owner)) {
      return action();
    }
    // 旧标签可能带桥接参数或章节标识，只保留应用内固定的步骤名前缀。
    final command = _webCommand.firstMatch(label)?.group(1);
    final stage = command == null
        ? label.split(_labelEnd).first.trim().split(' ').take(2).join(' ')
        : 'web.$command';
    if (_steps.length >= 64) {
      record('step.limit');
      return action();
    }
    final id = ++_sequence;
    final beginMs = _elapsedMs;
    final reported = <int>{};
    _steps[id] = (
      stage: stage,
      beginMs: beginMs,
      reported: reported,
      owner: owner,
    );
    record('step.begin:$stage:$id');
    _watchdog ??= Timer.periodic(const Duration(seconds: 1), (_) => _waiting());
    try {
      final result = await action();
      if (!_steps.containsKey(id)) return result;
      final details = <String, Object?>{
        'stepMs': _elapsedMs - beginMs,
        'moved': result is bool ? result : null,
      };
      if (incidentsOnly && reported.isNotEmpty) {
        incident('step.end:$stage:$id', details);
      } else {
        record('step.end:$stage:$id', details);
      }
      return result;
    } catch (error) {
      if (_steps.containsKey(id)) {
        incident('step.error:$stage:$id', {
          'stepMs': _elapsedMs - beginMs,
          'errorType': error.runtimeType.toString(),
          if (error is LayoutCancelled) 'cancelReason': error.reason.name,
        }, throttleKey: 'step.error');
      }
      rethrow;
    } finally {
      _steps.remove(id);
      _stopIdleWatchdog();
    }
  }

  void _waiting() {
    for (final entry in _steps.entries.toList()) {
      for (final seconds in [2, 10]) {
        if (_elapsedMs - entry.value.beginMs >= seconds * 1000 &&
            entry.value.reported.add(seconds)) {
          incident('step.waiting:${entry.value.stage}:${entry.key}:$seconds', {
            'stepMs': _elapsedMs - entry.value.beginMs,
          }, throttleKey: 'step.waiting:$seconds');
        }
      }
    }
    _stopIdleWatchdog();
  }

  void _stopIdleWatchdog() {
    if (_watchdog != null &&
        _steps.values.every((step) => step.reported.contains(10))) {
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
    _recent.clear();
    unawaited(flush());
  }
}

abstract final class ReaderTurnStateDiagnostics {
  static bool get enabled =>
      readerTurnStateDiagnosticsEnabled || Platform.isAndroid;
  static ReaderTurnStateRecorder? _recorder;
  static ReaderTurnStateRecorder get _log =>
      _recorder ??= ReaderTurnStateRecorder(
        append: (records) => AppErrors.store.appendReaderTurnState(records),
        incidentsOnly: !readerTurnStateDiagnosticsEnabled,
      );
  static void attach(
    Object owner,
    String scope,
    Map<String, Object?> Function() read, {
    bool observeStalls = false,
  }) {
    if (readerTurnStateDiagnosticsEnabled || observeStalls && enabled) {
      _log.attach(owner, scope, read);
    }
  }

  static void detach(Object owner) {
    _recorder?.detach(owner);
  }

  static void record(String event, [Map<String, Object?> details = const {}]) {
    if (enabled) _log.record(event, details);
  }

  static Future<T> step<T>(
    String label,
    Future<T> Function() action, {
    bool observeStalls = false,
    Object? owner,
  }) => readerTurnStateDiagnosticsEnabled || observeStalls && enabled
      ? _log.step(label, action, owner: owner)
      : action();

  static void pagePointerDown(int pointer) => _log.pagePointerDown(pointer);

  static void outerPointerDown(int pointer, {required bool expectsPage}) =>
      _log.outerPointerDown(pointer, expectsPage: expectsPage);

  static void blockedInput(Map<String, Object?> details) => _log.incident(
    'pageTurn.input.stillBlocked',
    details,
    throttleKey: 'blockedInput',
  );
  static Future<void> flush() async {
    await _recorder?.flush();
  }
}
