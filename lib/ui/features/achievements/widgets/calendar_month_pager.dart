import 'package:flutter/material.dart';

import 'calendar_month_viewport.dart';

/// 与阅读平移翻页一致：拖动直接改变位移，松手按 1/4 宽度或 420px/s 收尾。
class CalendarMonthPager extends StatefulWidget {
  const CalendarMonthPager({
    super.key,
    required this.initialMonth,
    required this.builder,
  });
  final DateTime initialMonth;
  final Widget Function(DateTime) builder;

  @override
  State<CalendarMonthPager> createState() => _CalendarMonthPagerState();
}

class _CalendarMonthPagerState extends State<CalendarMonthPager>
    with SingleTickerProviderStateMixin {
  late DateTime _month = DateTime(
    widget.initialMonth.year,
    widget.initialMonth.month,
  );
  final _shift = ValueNotifier<double>(0);
  late final _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  )..addListener(() => _shift.value = _tween!.value);
  Animation<double>? _tween;
  double _width = 0;
  int _direction = 0; // 1 下月，-1 上月；本轮起手后固定方向。
  bool _accepted = false, _settling = false;

  @override
  void dispose() {
    _controller.dispose();
    _shift.dispose();
    super.dispose();
  }

  void _start() {
    // 同阅读平移翻页：收尾中的新起手不在动画结束后半途接管。
    _accepted = !_settling;
    if (!_accepted) return;
    _direction = 0;
    setState(() {});
  }

  void _update(DragUpdateDetails details) {
    if (!_accepted) return;
    final dx = details.delta.dx;
    if (dx == 0) return;
    if (_direction == 0) _direction = dx < 0 ? 1 : -1;
    _shift.value = (_shift.value + dx).clamp(
      _direction == 1 ? -_width : 0,
      _direction == -1 ? _width : 0,
    );
  }

  void _end(DragEndDetails details) {
    if (!_accepted) return;
    _accepted = false;
    final velocity = details.velocity.pixelsPerSecond.dx;
    final committed =
        _direction != 0 &&
        (_shift.value.abs() > _width * 0.25 ||
            (_direction == 1 ? velocity < -420 : velocity > 420));
    _finish(committed ? _direction : 0);
  }

  void _cancel() {
    if (!_accepted) return;
    _accepted = false;
    _finish(0);
  }

  void _step(int direction) {
    if (_accepted || _settling) return;
    _finish(direction);
  }

  Future<void> _finish(int direction) async {
    setState(() => _settling = true);
    final target = -direction * _width;
    if (!MediaQuery.disableAnimationsOf(context) && _shift.value != target) {
      _tween = Tween<double>(
        begin: _shift.value,
        end: target,
      ).chain(CurveTween(curve: Curves.easeOutCubic)).animate(_controller);
      try {
        await _controller.forward(from: 0).orCancel;
      } on TickerCanceled {
        return;
      }
    }
    if (!mounted) return;
    // 新月份及零位移在同一帧交接，避免动画末尾闪回旧月。
    setState(() {
      _month = DateTime(_month.year, _month.month + direction);
      _settling = false;
      _direction = 0;
      _shift.value = 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    // 手指移动和收尾只更新视口位置，不逐帧重建三个月的日期按钮。
    final pages = [
      for (var delta = -1; delta <= 1; delta++)
        RepaintBoundary(
          key: ValueKey(DateTime(_month.year, _month.month + delta)),
          child: ExcludeSemantics(
            excluding: delta != 0,
            child: ExcludeFocus(
              excluding: delta != 0,
              child: IgnorePointer(
                ignoring: delta != 0,
                child: widget.builder(
                  DateTime(_month.year, _month.month + delta),
                ),
              ),
            ),
          ),
        ),
    ];
    return Semantics(
      label: '阅读日历，可左右滑动切换月份',
      onIncrease: () => _step(1),
      onDecrease: () => _step(-1),
      child: LayoutBuilder(
        builder: (context, constraints) {
          _width = constraints.maxWidth;
          return GestureDetector(
            key: const ValueKey('reading-calendar'),
            behavior: HitTestBehavior.opaque,
            onHorizontalDragStart: (_) => _start(),
            onHorizontalDragUpdate: _update,
            onHorizontalDragEnd: _end,
            onHorizontalDragCancel: _cancel,
            child: IgnorePointer(
              ignoring: _accepted || _settling,
              child: ValueListenableBuilder<double>(
                valueListenable: _shift,
                builder: (_, shift, _) =>
                    CalendarMonthViewport(shift: shift, children: pages),
              ),
            ),
          );
        },
      ),
    );
  }
}
