import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';

import 'app_errors.dart';

/// 记录 Dart 收到恢复通知及完成下一帧的时刻，和原生窗口记录互相对照。
final class AppResumeDiagnostics {
  int _resumeSequence = 0;

  void onStateChange(AppLifecycleState state) {
    if (!Platform.isAndroid || state == AppLifecycleState.inactive) return;
    record(state.name);
    if (state != AppLifecycleState.resumed) return;

    final sequence = ++_resumeSequence;
    final timer = Stopwatch()..start();
    final binding = WidgetsBinding.instance;
    // 只等应用本来会绘制的帧，不额外请求一帧，避免让诊断本身掩盖白屏。
    binding.addPostFrameCallback((_) {
      if (sequence == _resumeSequence &&
          binding.lifecycleState == AppLifecycleState.resumed) {
        record(
          'first_frame',
          frameWaitMs: timer.elapsedMilliseconds,
          sendingFrames: binding.sendFramesToEngine,
        );
      }
    });
  }

  static void record(String event, {int? frameWaitMs, bool? sendingFrames}) {
    if (!Platform.isAndroid) return;
    // Android 自己记录恢复前后的窗口。通道不可用时，诊断不影响正常启动。
    unawaited(
      AppErrors.channel
          .invokeMethod<void>('appResumeStep', {
            'event': event,
            'timeMs': DateTime.now().millisecondsSinceEpoch,
            'frameWaitMs': ?frameWaitMs,
            'sendingFrames': ?sendingFrames,
          })
          .catchError((Object _) {}),
    );
  }
}
