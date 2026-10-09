import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// 三个月提前布局；只移动已有图层，高度按拖动进度在两个真实月历之间插值。
/// 不用固定六行占位，也不等松手后再补一次高度动画。
class CalendarMonthViewport extends MultiChildRenderObjectWidget {
  const CalendarMonthViewport({
    super.key,
    required this.shift,
    required super.children,
  });
  final double shift;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _MonthViewport(shift);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderObject renderObject,
  ) {
    (renderObject as _MonthViewport).shift = shift;
  }
}

class _MonthViewport extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _MonthParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _MonthParentData> {
  _MonthViewport(this._shift);
  double _shift;
  set shift(double value) {
    if (value == _shift) return;
    _shift = value;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _MonthParentData) {
      child.parentData = _MonthParentData();
    }
  }

  @override
  void performLayout() {
    final width = constraints.maxWidth;
    final pages = getChildrenAsList(); // 上月、当前月、下月。
    final shift = _shift.clamp(-width, width);
    for (var i = 0; i < pages.length; i++) {
      pages[i].layout(
        BoxConstraints.tightFor(width: width),
        parentUsesSize: true,
      );
      (pages[i].parentData! as _MonthParentData).offset = Offset(
        (i - 1) * width + shift,
        0,
      );
    }
    final currentHeight = pages[1].size.height;
    final neighbourHeight = pages[shift > 0 ? 0 : 2].size.height;
    final progress = shift.abs() / width;
    size = constraints.constrain(
      Size(width, currentHeight + (neighbourHeight - currentHeight) * progress),
    );
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    context.pushClipRect(
      needsCompositing,
      offset,
      Offset.zero & size,
      defaultPaint,
    );
  }

  @override
  Rect describeApproximatePaintClip(RenderObject child) => Offset.zero & size;

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    final offset = (child.parentData! as _MonthParentData).offset;
    transform.translateByDouble(offset.dx, offset.dy, 0, 1);
  }
}

class _MonthParentData extends ContainerBoxParentData<RenderBox> {}
