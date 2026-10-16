import 'dart:async';
import 'dart:developer' show Timeline;
import 'dart:ui' show FramePhase;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'reader_work_trace.dart';

/// Diagnostics for the real app entry point, including shelf input and slow
/// frames before ReaderView exists. No work is installed in ordinary builds.
void installOpeningDiagnostics() {
  if (!readerWorkTraceEnabled) return;
  ReaderWorkTrace.start('diagnostic.build', {
    'release': kReleaseMode,
    'label': const String.fromEnvironment('GT_DIAGNOSTIC_LABEL'),
  })?.finish();
  if (const bool.fromEnvironment('GT_TRACE_APP_INPUT')) {
    unawaited(_traceInput());
  }
  if (const bool.fromEnvironment('GT_TRACE_OPENING_FRAMES')) {
    // 帧回调不会覆盖两帧之间的同步任务，另测事件循环延迟定位动画停顿。
    var previous = Timeline.now;
    Timer.periodic(const Duration(milliseconds: 16), (_) {
      final now = Timeline.now;
      final gap = now - previous;
      previous = now;
      if ((BookOpeningTrace.isActive ||
              const bool.fromEnvironment('GT_TRACE_STARTUP_GAPS')) &&
          gap >= 32000) {
        ReaderWorkTrace.start('app.event_loop_gap', {
          'startUs': now - gap,
          'gapUs': gap,
        })?.finish();
      }
    });
    WidgetsBinding.instance.addTimingsCallback((frames) {
      for (final frame in frames) {
        if (frame.buildDuration.inMicroseconds < 50000 &&
            frame.rasterDuration.inMicroseconds < 50000 &&
            frame.totalSpan.inMicroseconds < 100000) {
          continue;
        }
        ReaderWorkTrace.start('app.slow_frame', {
          'buildUs': frame.buildDuration.inMicroseconds,
          'rasterUs': frame.rasterDuration.inMicroseconds,
          'spanUs': frame.totalSpan.inMicroseconds,
          'vsyncUs': frame.timestampInMicroseconds(FramePhase.vsyncStart),
        })?.finish();
      }
    });
  }
}

Future<void> _traceInput() async {
  try {
    await const OptionalMethodChannel('gtreader/page_capture')
        .invokeMethod<void>('setInputTracing', true);
  } on PlatformException {
    // A diagnostic channel failure must not prevent the normal app startup.
  }
}
