import 'dart:math' as math;

import 'package:flutter/painting.dart';

/// 圆角边框用完整的外弧减内弧，再按每边宽度划分归属。
/// 不能用四条直线裁外圆角：那会漏掉转弯处，double也只剩中间两条短线。
void paintRoundedCssBorders(
  Canvas canvas,
  RRect outer,
  List<double> widths,
  List<int> styles,
  List<Color> colors,
) {
  final rect = outer.outerRect;
  final top = widths[0], right = widths[1];
  final bottom = widths[2], left = widths[3];
  RRect contour(double fraction) {
    Radius radius(double x, double y, double dx, double dy) =>
        Radius.elliptical(
          math.max(0, x - dx * fraction),
          math.max(0, y - dy * fraction),
        );
    return RRect.fromRectAndCorners(
      Rect.fromLTRB(
        rect.left + left * fraction,
        rect.top + top * fraction,
        rect.right - right * fraction,
        rect.bottom - bottom * fraction,
      ),
      topLeft: radius(outer.tlRadiusX, outer.tlRadiusY, left, top),
      topRight: radius(outer.trRadiusX, outer.trRadiusY, right, top),
      bottomRight: radius(outer.brRadiusX, outer.brRadiusY, right, bottom),
      bottomLeft: radius(outer.blRadiusX, outer.blRadiusY, left, bottom),
    ).scaleRadii();
  }

  // 拼接线沿“外角→内角”延伸。相邻边为0时，可见边拥有整段转弯，
  // 正好覆盖只有上下边的圆角标题；四边同宽时就是常见的45度拼接。
  Offset join(Offset corner, double dx, double dy) {
    final tx = dx == 0 ? double.infinity : rect.width / 2 / dx.abs();
    final ty = dy == 0 ? double.infinity : rect.height / 2 / dy.abs();
    final distance = math.min(tx, ty);
    return distance.isFinite ? corner + Offset(dx, dy) * distance : rect.center;
  }

  final tl = join(rect.topLeft, left, top);
  final tr = join(rect.topRight, -right, top);
  final br = join(rect.bottomRight, -right, -bottom);
  final bl = join(rect.bottomLeft, left, -bottom);
  final sectors = [
    [rect.topLeft, rect.topRight, tr, tl],
    [rect.topRight, rect.bottomRight, br, tr],
    [rect.bottomRight, rect.bottomLeft, bl, br],
    [rect.bottomLeft, rect.topLeft, tl, bl],
  ];
  for (var side = 0; side < 4; side++) {
    final thickness = widths[side];
    if (thickness <= 0) continue;
    final style = styles.length > side ? styles[side] : 1;
    final color = colors[side];
    final sector = Path()..addPolygon(sectors[side], true);
    canvas.save();
    canvas.clipPath(sector);
    void band(double start, double end, Color value) {
      canvas.drawDRRect(contour(start), contour(end), Paint()..color = value);
    }

    if (style == 4 && thickness >= 3) {
      final third = ((thickness + 1) / 3).floorToDouble() / thickness;
      band(0, third, color);
      band(1 - third, 1, color);
    } else if (style >= 5) {
      final firstSide = side == 0 || side == 3;
      final inset = style == 7 || style == 5;
      final outside = _borderTone(color, firstSide == inset);
      if (style == 7 || style == 8) {
        band(0, 1, outside);
      } else {
        final inside = _borderTone(color, firstSide != inset);
        band(0, .5, outside);
        band(.5, 1, inside);
      }
    } else if (style == 2 || style == 3) {
      final path = Path()..addRRect(contour(.5));
      final paint = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = thickness;
      for (final metric in path.computeMetrics()) {
        final dash = style == 3 ? thickness : thickness * 3.2;
        final gap = style == 3 ? thickness : thickness * 2.2;
        for (var at = 0.0; at < metric.length; at += dash + gap) {
          if (style == 3) {
            final tangent = metric.getTangentForOffset(at + dash / 2);
            if (tangent != null) {
              canvas.drawCircle(
                tangent.position,
                thickness / 2,
                Paint()..color = color,
              );
            }
          } else {
            canvas.drawPath(
              metric.extractPath(at, math.min(at + dash, metric.length)),
              paint,
            );
          }
        }
      }
    } else {
      band(0, 1, color);
    }
    canvas.restore();
  }
}

/// 完整边框盒共用的双线与凹凸线。side 为上、右、下、左，线宽就是边框带宽。
void paintCssBorderDetail(
  Canvas canvas,
  Rect area,
  int side,
  int style,
  Color color,
) {
  final horizontal = side == 0 || side == 2;
  final thickness = horizontal ? area.height : area.width;
  void band(double start, double end, Color value) {
    final rect = horizontal
        ? Rect.fromLTWH(area.left, area.top + start, area.width, end - start)
        : Rect.fromLTWH(area.left + start, area.top, end - start, area.height);
    canvas.drawRect(rect, Paint()..color = value);
  }

  if (style == 4) {
    // 浏览器在不足三像素时将 double 画成实线，否则保留中间空隙。
    if (thickness < 3) {
      band(0, thickness, color);
    } else {
      final third = ((thickness + 1) / 3).floorToDouble();
      band(0, third, color);
      band(thickness - third, thickness, color);
    }
    return;
  }
  final dark = _borderTone(color, true), light = _borderTone(color, false);
  final firstSide = side == 0 || side == 3;
  final inset = style == 7 || style == 5;
  final outside = firstSide == inset ? dark : light;
  if (style == 7 || style == 8) {
    band(0, thickness, outside);
  } else {
    final half = (thickness / 2).ceilToDouble();
    // groove/ridge 的内外两层方向相反；下边和右边从内侧开始切分。
    final inside = firstSide == inset ? light : dark;
    band(0, half, firstSide ? outside : inside);
    band(half, thickness, firstSide ? inside : outside);
  }
}

// Chromium 的凹凸边框对极暗色先增亮，避免黑色的两层都变成黑色；
// 普通颜色保持色相，以最大 RGB 分量增减0.33，浅色的亮边不再继续变白。
Color _borderTone(Color color, bool dark) {
  Color shift(Color value, bool lighter) {
    final argb = value.toARGB32();
    final rgb = [(argb >> 16) & 255, (argb >> 8) & 255, argb & 255];
    final largest = rgb.reduce(math.max);
    final next = lighter
        ? math.min(255.0, largest + 84.15)
        : math.max(0.0, largest - 84.15);
    final values = largest == 0
        ? [84, 84, 84]
        : [for (final c in rgb) (c * next / largest).round()];
    return Color.fromARGB((argb >> 24) & 255, values[0], values[1], values[2]);
  }

  final luminance = color.computeLuminance();
  if (luminance <= 0.014443844) {
    final light = shift(color, true);
    return dark ? light : shift(light, true);
  }
  if (dark) return shift(color, false);
  return luminance > 0.83077 ? color : shift(color, true);
}
