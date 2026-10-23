import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../view_models/automatic_reading.dart';
import '../../../../core/diagnostics/app_errors.dart';

/// 双页自动阅读沿用自动任务的暂停/常亮/生命周期，只替换推进方式。
class TimedPageTurn extends ConsumerStatefulWidget {
  const TimedPageTurn({
    super.key,
    required this.bookId,
    required this.ready,
    required this.turn,
    required this.revision,
    required this.child,
    this.pages = 2,
  });
  final String bookId;
  final bool Function() ready;
  final Future<bool> Function() turn;
  final Object revision;
  final int pages;
  final Widget child;
  @override
  ConsumerState<TimedPageTurn> createState() => _TimedPageTurnState();
}

class _TimedPageTurnState extends ConsumerState<TimedPageTurn>
    with SingleTickerProviderStateMixin {
  late final AutomaticReadingNotifier _automatic;
  late final AutomaticScrollBackend _backend;
  late final Ticker _ticker;
  double _elapsed = 0, _seconds = 8;
  Duration? _last;
  bool _running = false;
  Future<void>? _flight;
  @override
  void initState() {
    super.initState();
    _automatic = ref.read(automaticReadingProvider(widget.bookId).notifier);
    _ticker = createTicker(_tick);
    _backend = AutomaticScrollBackend(
      ready: () => widget.ready(),
      start: (seconds) async {
        _seconds = seconds;
        _running = true;
        _last = null;
        _ticker.start();
        _automatic.reportAdvancing(true);
      },
      stop: _stop,
      speed: (seconds) => _seconds = seconds,
      discard: () async {
        await _stop();
        _elapsed = 0;
      },
      retained: () => _elapsed > 0,
    );
    _automatic.attach(_backend);
  }

  Future<void> _stop() async {
    _running = false;
    _ticker.stop();
    _last = null;
    await _flight;
  }

  void _tick(Duration time) {
    final previous = _last;
    _last = time;
    if (!_running || _flight != null || !widget.ready() || previous == null) {
      return;
    }
    // 长帧或后台停顿不补翻多组页面。
    _elapsed += ((time - previous).inMicroseconds / 1000000).clamp(0, .1);
    if (_elapsed < _seconds * widget.pages) return;
    _elapsed = 0;
    _flight = () async {
      try {
        final moved = await widget.turn();
        if (mounted && !moved) _automatic.finish('已经是最后一页了');
      } catch (error, stack) {
        AppErrors.report(error, stack, operation: '双页自动翻页失败');
        if (mounted) _automatic.finish('自动翻页未完成');
      }
    }().whenComplete(() => _flight = null);
  }

  @override
  void didUpdateWidget(TimedPageTurn oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.revision != widget.revision) {
      _elapsed = 0;
      if (_running) {
        scheduleMicrotask(() {
          if (mounted) _automatic.pause();
        });
      }
    }
  }

  @override
  void dispose() {
    _running = false;
    _ticker.dispose();
    _automatic.detach(_backend);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
