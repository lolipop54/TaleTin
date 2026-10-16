import 'package:flutter/material.dart';

/// 在滚动识别器处理事件前登记来源。普通页面、弹窗和子路由均继承此设置。
class GtScrollInputScope extends StatefulWidget {
  const GtScrollInputScope({
    super.key,
    required this.child,
    this.behavior = const GtScrollBehavior(),
  });

  final Widget child;
  final ScrollBehavior behavior;

  @override
  State<GtScrollInputScope> createState() => _GtScrollInputScopeState();
}

class _GtScrollInputScopeState extends State<GtScrollInputScope> {
  bool _syntheticMove = false;

  @override
  Widget build(BuildContext context) => Listener(
    // 只登记本次事件，不重建界面、不阻断点击，也不改变触摸重采样。
    onPointerDown: (_) => _syntheticMove = false,
    onPointerMove: (event) => _syntheticMove = event.synthesized,
    onPointerUp: (_) => _syntheticMove = false,
    onPointerCancel: (_) => _syntheticMove = false,
    child: _ScrollInput(
      ignoreMove: () => _syntheticMove,
      child: ScrollConfiguration(
        behavior: widget.behavior,
        child: widget.child,
      ),
    ),
  );
}

class _ScrollInput extends InheritedWidget {
  const _ScrollInput({required this.ignoreMove, required super.child});

  final ValueGetter<bool> ignoreMove;

  @override
  bool updateShouldNotify(_ScrollInput oldWidget) => false;
}

/// 保留平台原来的物理设置和边界效果，只过滤补发触点造成的滚动位移。
/// 定制书架或目录效果时继承此类，避免局部 ScrollConfiguration 丢失过滤。
class GtScrollBehavior extends MaterialScrollBehavior {
  const GtScrollBehavior();

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) => _InputScrollPhysics(
    ignoreMove: context
        .getInheritedWidgetOfExactType<_ScrollInput>()
        ?.ignoreMove,
    parent: super.getScrollPhysics(context),
  );

  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) => ClipRect(child: super.buildOverscrollIndicator(context, child, details));
}

class _InputScrollPhysics extends ScrollPhysics {
  const _InputScrollPhysics({required this.ignoreMove, super.parent});

  final ValueGetter<bool>? ignoreMove;

  @override
  _InputScrollPhysics applyTo(ScrollPhysics? ancestor) => _InputScrollPhysics(
    ignoreMove: ignoreMove,
    parent: buildParent(ancestor),
  );

  @override
  double applyPhysicsToUserOffset(ScrollMetrics position, double offset) {
    // 真机抬手前的 synthesized move 会突然反向约 25dp，下一帧又被惯性带回。
    // Flutter 估速已排除这种事件；位移也与其保持一致，真实反向拖动仍立即生效。
    return ignoreMove?.call() == true
        ? 0
        : super.applyPhysicsToUserOffset(position, offset);
  }
}
