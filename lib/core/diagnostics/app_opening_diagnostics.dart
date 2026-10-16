import 'dart:async';
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
