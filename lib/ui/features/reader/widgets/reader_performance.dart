import 'dart:async';
import 'dart:convert';
import 'dart:developer' show Timeline;
import 'dart:ui' show FramePhase, FrameTiming;

import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import '../../../../core/diagnostics/reader_work_trace.dart';

const readerPerformanceEnabled = bool.fromEnvironment('GT_TRACE_READER_PERF');

/// 低频诊断：只记阶段、耗时和数量，不包含正文、图片路径或逐触点日志。
void readerPerf(
  String stage,
  int microseconds, [
  Map<String, Object?> details = const {},
]) {
  if (!readerPerformanceEnabled) return;
  debugPrint(
    'GT_READER_PERF ${jsonEncode({'stage': stage, 'us': microseconds, 'wallUs': DateTime.now().microsecondsSinceEpoch, 'atUs': Timeline.now, ...details})}',
  );
}

Future<T> measureReader<T>(String stage, Future<T> Function() action) async {
  if (!readerPerformanceEnabled) return action();
  final watch = Stopwatch()..start();
  try {
    return await action();
  } finally {
    readerPerf(stage, watch.elapsedMicroseconds);
  }
}

/// 全部阅读方式共用帧采样；只统计输入后真实产生的帧，不主动刷新屏幕。
/// Flutter 帧耗时不能代表 WebView 内部滚动，网页另记位置查询和帧间隔。
class ReaderPerformance extends StatefulWidget {
  const ReaderPerformance({
    super.key,
    required this.label,
    required this.child,
  });
  final String label;
  final Widget child;
  @override
  State<ReaderPerformance> createState() => _ReaderPerformanceState();
}

class _ReaderPerformanceState extends State<ReaderPerformance> {
  final _frames = <FrameTiming>[];
  Timer? _flushTimer;
  int _until = 0, _since = 0;
  double _refreshRate = 60;

  Future<void> _traceNativeInput(bool enabled) async {
    if (!readerPerformanceEnabled) return;
    // Real-opening diagnosis also needs the next shelf tap after leaving a book.
    if (!enabled && const bool.fromEnvironment('GT_TRACE_APP_INPUT')) return;
    // 两种排版一进入阅读就记录原生触摸，不依赖先截图或先打开原书。
    try {
      await const OptionalMethodChannel('gtreader/page_capture')
          .invokeMethod<void>('setInputTracing', enabled);
    } on PlatformException {
      // 诊断通道不可用也不影响阅读。
    }
  }

  @override
  void initState() {
    super.initState();
    if (readerPerformanceEnabled) {
      WidgetsBinding.instance.addTimingsCallback(_timings);
      unawaited(_traceNativeInput(true));
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!readerPerformanceEnabled) return;
    final view = View.of(context);
    _refreshRate = view.display.refreshRate > 0 ? view.display.refreshRate : 60;
    readerPerf('reader.context', 0, {
      'mode': widget.label,
      'refreshHz': _refreshRate,
      'dpr': view.devicePixelRatio,
      'width': view.physicalSize.width,
      'height': view.physicalSize.height,
    });
  }

  void _input(PointerEvent event) {
    // 只记按下与松手，和 Android 原生触摸时间配对，避免移动事件刷日志。
    if (event is PointerDownEvent || event is PointerUpEvent || event is PointerCancelEvent) {
      ReaderWorkTrace.start('reader.input', {
        'phase': event is PointerDownEvent ? 'down' : event is PointerUpEvent ? 'up' : 'cancel',
        'pointer': event.pointer, 'eventUs': event.timeStamp.inMicroseconds,
        'x': event.localPosition.dx, 'y': event.localPosition.dy, 'mode': widget.label,
      })?.finish();
    }
    final now = Timeline.now;
    if (now > _until) _since = now;
    _until = now + 1000000;
  }

  void _timings(List<FrameTiming> frames) {
    for (final frame in frames) {
      final at = frame.timestampInMicroseconds(FramePhase.vsyncStart);
      if (at >= _since && at <= _until) _frames.add(frame);
    }
    if (_frames.isNotEmpty) {
      _flushTimer ??= Timer(const Duration(milliseconds: 500), _flush);
    }
  }

  void _flush({String? mode}) {
    _flushTimer?.cancel();
    _flushTimer = null;
    if (_frames.isEmpty) return;
    final builds = _frames.map((f) => f.buildDuration.inMicroseconds).toList()
      ..sort();
    final rasters = _frames.map((f) => f.rasterDuration.inMicroseconds).toList()
      ..sort();
    readerPerf('flutter.frames', 0, {
      'mode': mode ?? widget.label,
      'count': _frames.length,
      'buildP95Us': builds[(builds.length * .95).ceil() - 1],
      'buildMaxUs': builds.last,
      'rasterP95Us': rasters[(rasters.length * .95).ceil() - 1],
      'rasterMaxUs': rasters.last,
      'refreshHz': _refreshRate,
      'overFrameBudget': _frames
          .where(
            (f) =>
                f.buildDuration.inMicroseconds > 1000000 / _refreshRate ||
                f.rasterDuration.inMicroseconds > 1000000 / _refreshRate,
          )
          .length,
      'over16ms': _frames
          .where(
            (f) =>
                f.buildDuration.inMicroseconds > 16667 ||
                f.rasterDuration.inMicroseconds > 16667,
          )
          .length,
    });
    _frames.clear();
  }

  @override
  void didUpdateWidget(ReaderPerformance oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.label != widget.label) {
      _flush(mode: oldWidget.label);
      readerPerf('reader.mode', 0, {'mode': widget.label});
      _until = 0;
    }
  }

  @override
  Widget build(BuildContext context) => !readerPerformanceEnabled
      ? widget.child
      : Listener(
          onPointerDown: _input,
          onPointerMove: _input,
          onPointerUp: _input,
          behavior: HitTestBehavior.translucent,
          child: widget.child,
        );

  @override
  void dispose() {
    if (readerPerformanceEnabled) {
      WidgetsBinding.instance.removeTimingsCallback(_timings);
      _flush();
      unawaited(_traceNativeInput(false));
    }
    _flushTimer?.cancel();
    super.dispose();
  }
}
