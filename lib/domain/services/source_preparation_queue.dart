import 'dart:async';

import '../../core/diagnostics/reader_work_trace.dart';

/// 准备任务逐本执行；开书提升尚未开始的目标，正在执行的一本正常收尾。
/// 同一来源共用一个结果，避免书架和开书各解析一次。
class SourcePreparationQueue<T> {
  final _waiting = <_Preparation<T>>[];
  final _tasks = <String, _Preparation<T>>{};
  bool _running = false;

  Future<T>? pending(String key, {bool priority = false}) {
    final task = _tasks[key];
    if (task == null) return null;
    if (priority && _waiting.remove(task)) _waiting.insert(0, task);
    return task.result.future;
  }

  Future<T> add(
    String key,
    Future<T> Function() action, {
    bool priority = false,
  }) {
    final existing = _tasks[key];
    if (existing != null) {
      if (priority && _waiting.remove(existing)) _waiting.insert(0, existing);
      return existing.result.future;
    }
    final task = _Preparation(
      key,
      action,
      ReaderWorkTrace.start('source.queue', {
        'sourceKey': key.hashCode,
        'waitingAhead': _waiting.length,
        'alreadyRunning': _running,
        'priority': priority,
      }),
    );
    _tasks[key] = task;
    if (priority) {
      _waiting.insert(0, task);
    } else {
      _waiting.add(task);
    }
    if (!_running) unawaited(_run());
    return task.result.future;
  }

  Future<void> _run() async {
    _running = true;
    while (_waiting.isNotEmpty) {
      final task = _waiting.removeAt(0);
      task.trace?.mark('queue_wait');
      try {
        task.result.complete(await task.action());
      } catch (error, stack) {
        task.trace?.finish(status: error.runtimeType.toString());
        task.result.completeError(error, stack);
      } finally {
        task.trace?.finish();
        _tasks.remove(task.key);
      }
    }
    _running = false;
  }
}

class _Preparation<T> {
  _Preparation(this.key, this.action, this.trace);
  final String key;
  final ReaderWorkTrace? trace;
  final Future<T> Function() action;
  final result = Completer<T>();
}
