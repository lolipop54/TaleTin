import 'dart:async';

import 'package:flutter/scheduler.dart';

/// 原生滚动不断产生纹理，但纹理到达后才唤醒 Flutter 容易错过本次刷新。
/// 运动期间维持 Flutter 的帧调度；不重建正文，也不驱动网页滚动或改动惯性。
class OriginalScrollFrames {
  OriginalScrollFrames(TickerProvider vsync)
    : _ticker = vsync.createTicker((_) {});

  final Ticker _ticker;
  Timer? _idle;
  bool _foreground = true;

  bool get isActive => _ticker.isActive;

  void motion() {
    if (!_foreground) return;
    if (!_ticker.isActive) _ticker.start();
    _idle?.cancel();
    // 沿用网页的250ms停稳间隔。原生滚动回调涵盖手指和惯性，短按、
    // 到达边界或原生没有继续滚动时也会自动停止，不依赖网页一定回报。
    _idle = Timer(const Duration(milliseconds: 250), stop);
  }

  void setForeground(bool foreground) {
    _foreground = foreground;
    if (!foreground) stop();
  }

  void stop() {
    _idle?.cancel();
    _idle = null;
    _ticker.stop();
  }

  void dispose() {
    _idle?.cancel();
    _ticker.dispose();
  }
}
