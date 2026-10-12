import 'package:flutter/material.dart';

import '../reader_sheet.dart';

/// 目录、书签与笔记共用的滚动区域，保留边界拉伸和真实拖动。
class ContentsScrollArea extends StatefulWidget {
  const ContentsScrollArea({super.key, required this.child});

  final Widget child;

  @override
  State<ContentsScrollArea> createState() => _ContentsScrollAreaState();
}

class _ContentsScrollAreaState extends State<ContentsScrollArea> {
  bool _syntheticMove = false;

  @override
  Widget build(BuildContext context) => ClipRect(
    child: Listener(
      // Listener 在拖动识别器处理本次事件之前收到它；这里只登记事件来源，
      // 不重建界面，也不拦截真实拖动、点击或惯性。
      onPointerDown: (_) => _syntheticMove = false,
      onPointerMove: (event) => _syntheticMove = event.synthesized,
      onPointerUp: (_) => _syntheticMove = false,
      onPointerCancel: (_) => _syntheticMove = false,
      child: ScrollConfiguration(
        behavior: _ContentsScrollBehavior(() => _syntheticMove),
        child: widget.child,
      ),
    ),
  );
}

class _ContentsScrollBehavior extends MaterialScrollBehavior {
  const _ContentsScrollBehavior(this.ignoreMove);

  final ValueGetter<bool> ignoreMove;

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) =>
      _ContentsScrollPhysics(ignoreMove: ignoreMove);

  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) => super.buildOverscrollIndicator(
    context,
    // 底色一起参与拉伸，透明留白不会露出面板后方的原书正文。
    ColoredBox(color: ReaderSheet.backgroundOf(context), child: child),
    details,
  );
}

class _ContentsScrollPhysics extends ClampingScrollPhysics {
  const _ContentsScrollPhysics({required this.ignoreMove, super.parent});

  final ValueGetter<bool> ignoreMove;

  @override
  _ContentsScrollPhysics applyTo(ScrollPhysics? ancestor) =>
      _ContentsScrollPhysics(
        ignoreMove: ignoreMove,
        parent: buildParent(ancestor),
      );

  @override
  double applyPhysicsToUserOffset(ScrollMetrics position, double offset) {
    // 安卓原书页面实测：抬手前补发的 synthesized move 会突然反向约 25dp，
    // 下一帧又被真实惯性带回边界。Flutter 已不把此类事件用于估速，
    // 这里也不把它当作列表位移；真实反向拖动照常立即生效。
    return ignoreMove() ? 0 : super.applyPhysicsToUserOffset(position, offset);
  }
}
