import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

/// 分页下半屏上滑、滚动全屏左滑64dp后松手退出；往回拖动可取消。
///
/// 观察原始触摸而不抢占手势：分页仍可横翻、长按选字，滚动和原生网页也能
/// 使用同一触摸观察流程，滚动模式的上下滑动不触发退出。
class ReaderSwipeExitGesture extends StatefulWidget {
  const ReaderSwipeExitGesture({
    super.key,
    required this.enabled,
    required this.onExit,
    required this.child,
    this.scrolling = false,
    this.canSwipe,
  });

  final bool enabled;
  final VoidCallback onExit;
  final Widget child;
  final bool scrolling;

  /// PDF正在缩放、移动或准备视窗时，不把单指移动解释为退出。
  final bool Function()? canSwipe;

  @override
  State<ReaderSwipeExitGesture> createState() => _ReaderSwipeExitGestureState();
}

class _ReaderSwipeExitGestureState extends State<ReaderSwipeExitGesture> {
  final _pointers = <int>{};
  int? _pointer;
  Offset _travel = Offset.zero;
  Duration _started = Duration.zero;
  bool _directionAccepted = false;

  bool get _enabled => widget.enabled && (widget.canSwipe?.call() ?? true);

  @override
  void didUpdateWidget(ReaderSwipeExitGesture oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled || oldWidget.scrolling != widget.scrolling) {
      _pointer = null;
    }
  }

  void _down(PointerDownEvent event, double height) {
    _pointers.add(event.pointer);
    // 一轮触摸出现第二根手指后整轮作废，不能缩放结束时再误退出。
    if (_pointers.length != 1) {
      _pointer = null;
      return;
    }
    if (!_enabled ||
        (!widget.scrolling && event.localPosition.dy < height * .5)) {
      return;
    }
    _pointer = event.pointer;
    _started = event.timeStamp;
    _travel = Offset.zero;
    _directionAccepted = false;
  }

  void _move(PointerMoveEvent event) {
    if (_pointer != event.pointer || event.synthesized) return;
    if (!_enabled ||
        (!_directionAccepted &&
            event.timeStamp - _started >= kLongPressTimeout)) {
      _pointer = null;
      return;
    }
    _travel += event.localDelta;
    if (_directionAccepted) return;
    final slop = computeHitSlop(
      event.kind,
      MediaQuery.gestureSettingsOf(context),
    );
    if (_travel.distance <= slop) return;
    // 与下拉书签相同的约18度方向范围，按当前阅读方式旋转到上方或左方。
    // 起手方向不匹配后整轮作废，避免正常滚动中途斜移变成退出。
    _directionAccepted = _inExitDirection;
    if (!_directionAccepted) _pointer = null;
  }

  double get _distance => widget.scrolling ? -_travel.dx : -_travel.dy;
  bool get _inExitDirection =>
      _distance > (widget.scrolling ? _travel.dy : _travel.dx).abs() * 3;

  void _end(PointerEvent event, {bool cancelled = false}) {
    final exit =
        !cancelled &&
        _pointer == event.pointer &&
        _directionAccepted &&
        _enabled &&
        _inExitDirection &&
        _distance >= 64;
    _pointers.remove(event.pointer);
    if (_pointer == event.pointer) _pointer = null;
    if (exit) widget.onExit();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (event) => _down(event, constraints.maxHeight),
      onPointerMove: _move,
      onPointerUp: _end,
      onPointerCancel: (event) => _end(event, cancelled: true),
      child: widget.child,
    ),
  );
}
