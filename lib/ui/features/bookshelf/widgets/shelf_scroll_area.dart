import 'package:flutter/material.dart';

import '../../../core/theme/gt_tokens.dart';
import '../../../core/widgets/gt_scroll_input_scope.dart';

/// 书架滚动区：保留系统拉伸，顶部固定渐隐，并统一裁掉绘制越界。
class ShelfScrollArea extends StatelessWidget {
  const ShelfScrollArea({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => ClipRect(
    child: CustomPaint(
      foregroundPainter: _TopFadePainter(
        background: context.gtColors.canvas,
        pixel: 1 / MediaQuery.devicePixelRatioOf(context),
      ),
      child: GtScrollInputScope(
        behavior: const _ShelfScrollBehavior(),
        child: child,
      ),
    ),
  );
}

/// 拉伸单独采样内容，顶部和两侧的留白也需要不透明底色。
class _ShelfScrollBehavior extends GtScrollBehavior {
  const _ShelfScrollBehavior();

  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) => super.buildOverscrollIndicator(
    context,
    ColoredBox(color: context.gtColors.canvas, child: child),
    details,
  );
}

class _TopFadePainter extends CustomPainter {
  const _TopFadePainter({required this.background, required this.pixel});

  final Color background;
  final double pixel;

  @override
  void paint(Canvas canvas, Size size) {
    // 分类栏高度可能落在半个屏幕像素上。矩形向上多画一像素，
    // 首像素保持实色，避免矩形抗锯齿边缘漏出下面的深色封面。
    // 最外层 ClipRect 同时裁掉拉伸滤镜和渐变的越界绘制；
    // Stack 默认只按布局溢出裁剪，不能保证滤镜绘制仍在边界内。
    final bounds = Rect.fromLTWH(0, 0, size.width, GtSpacing.s4);
    canvas.drawRect(
      Rect.fromLTRB(0, -pixel, size.width, GtSpacing.s4),
      Paint()
        ..isAntiAlias = false
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [background, background, background.withValues(alpha: 0)],
          stops: [0, pixel / GtSpacing.s4, 1],
        ).createShader(bounds),
    );
  }

  @override
  bool shouldRepaint(_TopFadePainter oldDelegate) =>
      background != oldDelegate.background || pixel != oldDelegate.pixel;
}
