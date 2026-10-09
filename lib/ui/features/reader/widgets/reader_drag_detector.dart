import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import 'turn_trace.dart';

/// 原书和简化横拖统一使用5dp启动距离，点击和长按仍使用平台防抖距离。
/// 保留 Flutter 手势竞争，长按选字取得手势后不会被翻页抢走。
class ReaderDragDetector extends StatelessWidget {
  const ReaderDragDetector({
    super.key,
    this.child = const SizedBox.expand(),
    this.onTapUp,
    this.onHorizontalDragStart,
    this.onHorizontalDragUpdate,
    this.onHorizontalDragEnd,
    this.onHorizontalDragCancel,
  });

  final Widget child;
  final GestureTapUpCallback? onTapUp;
  final GestureDragStartCallback? onHorizontalDragStart;
  final GestureDragUpdateCallback? onHorizontalDragUpdate;
  final GestureDragEndCallback? onHorizontalDragEnd;
  final GestureDragCancelCallback? onHorizontalDragCancel;

  @override
  Widget build(BuildContext context) {
    return RawGestureDetector(
      behavior: HitTestBehavior.opaque,
      gestures: {
        _ReaderHorizontalDragRecognizer:
            GestureRecognizerFactoryWithHandlers<
              _ReaderHorizontalDragRecognizer
            >(
              () => _ReaderHorizontalDragRecognizer(debugOwner: this),
              (recognizer) => recognizer
                ..dragStartBehavior = DragStartBehavior.down
                ..onlyAcceptDragOnThreshold = true
                ..gestureSettings = const DeviceGestureSettings(touchSlop: 5)
                ..onStart = onHorizontalDragStart
                ..onUpdate = onHorizontalDragUpdate
                ..onEnd = onHorizontalDragEnd
                ..onCancel = onHorizontalDragCancel,
            ),
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: onTapUp,
        child: child,
      ),
    );
  }
}

/// 近竖直方向留给书签，其余斜拖按横向分量翻页；启动距离仍为5dp。
class _ReaderHorizontalDragRecognizer extends HorizontalDragGestureRecognizer {
  _ReaderHorizontalDragRecognizer({super.debugOwner});
  Offset _travel = Offset.zero;
  int? _pointer;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    if (_pointer == null) {
      _pointer = event.pointer;
      _travel = Offset.zero;
    }
    super.addAllowedPointer(event);
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event is PointerMoveEvent && event.pointer == _pointer) {
      _travel += event.delta;
    }
    super.handleEvent(event);
  }

  @override
  bool hasSufficientGlobalDistanceToAccept(
    PointerDeviceKind kind,
    double? slop,
  ) {
    final x = _travel.dx.abs(), y = _travel.dy.abs();
    if (x * 3 <= y) return false;
    return super.hasSufficientGlobalDistanceToAccept(kind, slop);
  }

  @override
  void acceptGesture(int pointer) {
    traceTurn('arena accepted pointer=$pointer travel=$_travel');
    super.acceptGesture(pointer);
  }

  @override
  void rejectGesture(int pointer) {
    traceTurn('arena rejected pointer=$pointer travel=$_travel');
    super.rejectGesture(pointer);
  }

  @override
  void didStopTrackingLastPointer(int pointer) {
    super.didStopTrackingLastPointer(pointer);
    _pointer = null;
  }
}

/// 书签只处理向下拉。向上起手不能抢走之后转成横向的翻页手势。
/// 保留方向判断和平台触摸容差，长按选字仍可正常参与竞争。
class ReaderPullDownRecognizer extends VerticalDragGestureRecognizer {
  ReaderPullDownRecognizer({super.debugOwner}) {
    onlyAcceptDragOnThreshold = true;
  }

  Offset _travel = Offset.zero;
  int? _pointer;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    if (_pointer == null) {
      _pointer = event.pointer;
      _travel = Offset.zero;
    }
    super.addAllowedPointer(event);
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event is PointerMoveEvent && event.pointer == _pointer) {
      _travel += event.delta;
    }
    super.handleEvent(event);
  }

  @override
  bool hasSufficientGlobalDistanceToAccept(
    PointerDeviceKind pointerDeviceKind,
    double? deviceTouchSlop,
  ) =>
      // 只接受竖直轴左右约18度内的下拉。开始后不再锁方向，仍可上推取消。
      _travel.dy > _travel.dx.abs() * 3 &&
      super.hasSufficientGlobalDistanceToAccept(pointerDeviceKind, deviceTouchSlop);

  @override
  void didStopTrackingLastPointer(int pointer) {
    super.didStopTrackingLastPointer(pointer);
    _pointer = null;
  }
}
