import 'package:flutter/foundation.dart';
import 'dart:convert';
import 'reader_performance.dart';
export 'reader_performance.dart' show measureReader, readerPerf, readerPerformanceEnabled;

const turnTraceEnabled = bool.fromEnvironment('GT_TRACE_TURN');
const turnFrameTraceEnabled = bool.fromEnvironment('GT_TRACE_FRAMES');
int _step = 0;
final _samples = <String, List<Object>>{};

/// 只在专项真机诊断包开启，正式包不记录手势日志，也不额外截图或测量。
void traceTurn(String message) {
  if (turnTraceEnabled) {
    debugPrint('GT_TURN ${DateTime.now().microsecondsSinceEpoch} $message');
  }
}

/// 每批最多 4 个移动点，控制在设备单行日志长度内；保留原始时间以分析延迟。
void traceTurnSample(String key, Object sample) {
  if (!turnTraceEnabled) return;
  final list = _samples.putIfAbsent(key, () => []);
  list.add([DateTime.now().microsecondsSinceEpoch, sample]);
  if (list.length >= 4) traceTurnFlush(key);
}

void traceTurnFlush(String key) {
  if (!turnTraceEnabled) return;
  final list = _samples.remove(key);
  if (list != null) traceTurn('samples $key ${jsonEncode(list)}');
}

/// 只包住已有等待，不增加查询、截图或帧等待；成对编号可识别尚未返回的步骤。
Future<T> traceTurnStep<T>(String label, Future<T> Function() action) async {
  if (!turnTraceEnabled) {
    // 拖动桥接另做汇总，避免开启诊断后逐点输出反而拖慢跟手。
    return label.contains('command=__gt.drag') ? action() : measureReader(label, action);
  }
  final step = ++_step;
  final watch = Stopwatch()..start();
  traceTurn('step=$step begin $label');
  try {
    final result = await action();
    traceTurn('step=$step end us=${watch.elapsedMicroseconds} $label');
    return result;
  } catch (error) {
    traceTurn('step=$step error us=${watch.elapsedMicroseconds} $label type=${error.runtimeType}');
    rethrow;
  }
}
