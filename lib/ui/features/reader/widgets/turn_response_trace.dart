import 'package:flutter/widgets.dart';

import 'turn_trace.dart';

/// 诊断触摸接收、首次变化帧提交和整轮交接。只观察已有帧，不主动请求绘制。
/// post-frame 表示 Flutter 已提交这一帧，不等同于屏幕首像素或完成光栅化。
class TurnResponseTrace {
  final _inputs = <int, Stopwatch>{};
  final _submitted = <int>{};
  final _firstMoves = <int, int>{};
  final _recognized = <int, int>{};
  final _latestMoves = <int, int>{};
  int _lastSampleUs = 0;
  int? active;

  void begin(int pointer, Duration source) {
    if (!turnTraceEnabled && !turnFrameTraceEnabled) return;
    _inputs[pointer] = Stopwatch()..start();
    if (_inputs.length > 8) {
      final oldest = _inputs.keys.first;
      _inputs.remove(oldest);
      _submitted.remove(oldest);
      _firstMoves.remove(oldest);
      _recognized.remove(oldest);
      _latestMoves.remove(oldest);
    }
    traceTurn(
      'response down pointer=$pointer sourceUs=${source.inMicroseconds}',
    );
  }

  void move(int pointer, Duration source) {
    if (!turnTraceEnabled) return;
    final us = _inputs[pointer]?.elapsedMicroseconds;
    if (us == null) return;
    if (!_firstMoves.containsKey(pointer)) {
      _firstMoves[pointer] = us;
      traceTurn(
        'response first-move pointer=$pointer downToMoveUs=$us '
        'sourceUs=${source.inMicroseconds}',
      );
    }
    _latestMoves[pointer] = us;
  }

  void recognized(int? pointer) {
    if ((!turnTraceEnabled && !turnFrameTraceEnabled) || pointer == null) return;
    final us = _inputs[pointer]?.elapsedMicroseconds;
    if (us == null) return;
    _recognized[pointer] = us;
    traceTurn(
      'response recognized pointer=$pointer downToRecognizedUs=$us '
      'moveToRecognizedUs=${us - (_firstMoves[pointer] ?? 0)}',
    );
  }

  void activate(int? pointer) {
    if (!turnTraceEnabled && !turnFrameTraceEnabled) return;
    active = pointer;
    _lastSampleUs = 0;
    traceTurn(
      'response activate pointer=$pointer waitUs=${_inputs[pointer]?.elapsedMicroseconds}',
    );
  }

  void changedFrame(String label) {
    if (!turnTraceEnabled && !turnFrameTraceEnabled) return;
    final pointer = active, watch = _inputs[active];
    if (pointer == null || watch == null) return;
    if (!_submitted.add(pointer)) {
      if (!turnTraceEnabled) return;
      final move = _latestMoves[pointer];
      if (move == null || move - _lastSampleUs < 100000) return;
      _lastSampleUs = move;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        traceTurnSample('follow-$pointer', [
          move,
          watch.elapsedMicroseconds - move,
        ]);
      });
      return;
    }
    final buildUs = watch.elapsedMicroseconds;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (turnFrameTraceEnabled) {
        // 重采样会改写 PointerEvent.timeStamp，不能把它当作原始触摸时间。
        // 起手总等待由分析脚本对照 Android 原始 down 日志与此帧时间计算。
        final frameUs = WidgetsBinding.instance.currentSystemFrameTimeStamp.inMicroseconds;
        debugPrint('TURN_RESPONSE $label pointer=$pointer '
            'frameUs=$frameUs '
            'receivedToSubmitUs=${watch.elapsedMicroseconds}');
      }
      traceTurn(
        'response first-frame-submitted pointer=$pointer label=$label '
        'buildUs=$buildUs receivedToSubmitUs=${watch.elapsedMicroseconds} '
        'recognizedToSubmitUs=${watch.elapsedMicroseconds - (_recognized[pointer] ?? 0)}',
      );
    });
  }

  void finish(int? pointer) {
    if (!turnTraceEnabled) return;
    traceTurnFlush('follow-$pointer');
    traceTurn(
      'response finished pointer=$pointer '
      'receivedToFinishUs=${_inputs[pointer]?.elapsedMicroseconds} '
      'changedFrame=${_submitted.contains(pointer)}',
    );
  }
}
