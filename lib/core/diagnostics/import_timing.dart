import 'dart:convert';
import 'dart:developer' show Timeline;

/// 只在专项验证构建启用；普通构建不创建计时器，也不输出书籍资料。
const traceImportPerf = bool.fromEnvironment('GT_TRACE_IMPORT_PERF');

/// 同一流程的相邻检查点构成互不重叠的阶段；细项包含在所属阶段内。
class ImportTiming {
  ImportTiming(this.scope);

  final String scope;
  final Stopwatch _clock = Stopwatch()..start();
  final Map<String, int> _stages = {};
  final Map<String, int> _details = {};
  final Map<String, int> _counts = {};
  int _previous = 0;

  void mark(String stage) {
    final now = _clock.elapsedMicroseconds;
    _stages.update(
      stage,
      (value) => value + now - _previous,
      ifAbsent: () => now - _previous,
    );
    _previous = now;
  }

  T detail<T>(String name, T Function() action) {
    final start = _clock.elapsedMicroseconds;
    try {
      return action();
    } finally {
      final elapsed = _clock.elapsedMicroseconds - start;
      _details.update(
        name,
        (value) => value + elapsed,
        ifAbsent: () => elapsed,
      );
    }
  }

  /// Add native timings. Parallel CPU sums are labelled separately from wall time.
  void recordDetail(String name, int microseconds) {
    _details.update(
      name,
      (value) => value + microseconds,
      ifAbsent: () => microseconds,
    );
  }

  void count(String name, int value) => _counts.update(
    name,
    (previous) => previous + value,
    ifAbsent: () => value,
  );

  /// 仅输出阶段名、耗时和数量，不输出路径、书名、正文或位置。
  void report({Map<String, int> counts = const {}}) {
    mark('remaining');
    _clock.stop();
    // ignore: avoid_print
    print(
      '[IMPORT_TIMING] ${jsonEncode({
        'scope': scope,
        'wallUs': DateTime.now().microsecondsSinceEpoch,
        'atUs': Timeline.now,
        'totalUs': _previous,
        'stagesUs': _stages,
        'detailsUs': _details,
        'counts': {..._counts, ...counts},
      })}',
    );
  }
}
