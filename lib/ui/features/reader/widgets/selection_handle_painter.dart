import 'package:flutter/rendering.dart';

/// 小圆点只负责显示，44dp 的触摸框单独保留，不能跟着缩小。
const double kHandleTouchSize = 44;
const double kHandleRadius = 5;
const double kHandleStrokeWidth = 1.5;
const double kHandleOutlineWidth = 1;

/// 圆心距文字底边2dp，半径独立调整；上缘压住高亮3dp。
const double kHandleCenterOffset = 2;

/// 触摸框以圆点为中心；文字底边在框内的高度。
const double kHandleAnchorOffset = kHandleTouchSize / 2 - kHandleCenterOffset;

/// 细竖线贯穿端点字高，底部接带白边的小圆点；分页、拖动与滚动共用。
class SelectionHandlePainter extends CustomPainter {
  const SelectionHandlePainter({required this.color, required this.lineHeight});

  final Color color;
  final double lineHeight;

  static void paintAt(
    Canvas canvas,
    Offset anchor, {
    required Color color,
    required double lineHeight,
  }) {
    final fill = Paint()..color = color;
    final center = anchor + const Offset(0, kHandleCenterOffset);
    canvas.drawRect(
      Rect.fromLTRB(
        anchor.dx - kHandleStrokeWidth / 2,
        anchor.dy - lineHeight,
        anchor.dx + kHandleStrokeWidth / 2,
        center.dy,
      ),
      fill,
    );
    // 描边向圆内收，外轮廓仍是参考图的小圆点，不扩大手柄。
    canvas.drawCircle(
      center,
      kHandleRadius,
      Paint()..color = const Color(0xFFFFFFFF),
    );
    canvas.drawCircle(center, kHandleRadius - kHandleOutlineWidth, fill);
  }

  @override
  void paint(Canvas canvas, Size size) => paintAt(
    canvas,
    Offset(size.width / 2, kHandleAnchorOffset),
    color: color,
    lineHeight: lineHeight,
  );

  @override
  bool shouldRepaint(SelectionHandlePainter old) =>
      old.color != color || old.lineHeight != lineHeight;
}
