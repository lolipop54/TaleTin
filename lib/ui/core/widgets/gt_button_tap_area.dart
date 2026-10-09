import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// 为旧样式按钮保留最小触摸范围，内容保持原尺寸并居中。
/// 直接传递父布局约束，所以整行按钮、指定高度按钮仍填满原来的区域。
class GtButtonTapArea extends SingleChildRenderObjectWidget {
  const GtButtonTapArea({super.key, required this.minimumSize, required super.child});
  final Size minimumSize;
  @override
  RenderObject createRenderObject(BuildContext context) => _TapArea(minimumSize);
  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) {
    final area = renderObject as _TapArea;
    if (area.minimumSize != minimumSize) {
      area.minimumSize = minimumSize;
      area.markNeedsLayout();
    }
  }
}

class _TapArea extends RenderShiftedBox {
  _TapArea(this.minimumSize) : super(null);
  Size minimumSize;
  Size _sizeFor(Size content, BoxConstraints constraints) => constraints.constrain(
    Size(math.max(content.width, minimumSize.width), math.max(content.height, minimumSize.height)),
  );
  @override
  double computeMinIntrinsicWidth(double height) =>
      math.max(super.computeMinIntrinsicWidth(height), minimumSize.width);
  @override
  double computeMaxIntrinsicWidth(double height) =>
      math.max(super.computeMaxIntrinsicWidth(height), minimumSize.width);
  @override
  double computeMinIntrinsicHeight(double width) =>
      math.max(super.computeMinIntrinsicHeight(width), minimumSize.height);
  @override
  double computeMaxIntrinsicHeight(double width) =>
      math.max(super.computeMaxIntrinsicHeight(width), minimumSize.height);
  @override
  Size computeDryLayout(BoxConstraints constraints) =>
      _sizeFor(child!.getDryLayout(constraints), constraints);
  @override
  double? computeDryBaseline(BoxConstraints constraints, TextBaseline baseline) {
    final value = child!.getDryBaseline(constraints, baseline);
    if (value == null) return null;
    final contentSize = child!.getDryLayout(constraints);
    return value + (_sizeFor(contentSize, constraints).height - contentSize.height) / 2;
  }

  @override
  void performLayout() {
    child!.layout(constraints, parentUsesSize: true);
    size = _sizeFor(child!.size, constraints);
    final data = child!.parentData! as BoxParentData;
    data.offset = Offset(
      (size.width - child!.size.width) / 2,
      (size.height - child!.size.height) / 2,
    );
  }
}
