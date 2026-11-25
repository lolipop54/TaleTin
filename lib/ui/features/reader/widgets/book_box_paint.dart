import 'dart:math' as math;

import 'package:flutter/painting.dart';

import '../../../../engine/layout/measured_block.dart';
import '../../../core/theme/reading_theme.dart';
import 'book_colors.dart';
import 'book_shadow_paint.dart';
import 'css_background_paint.dart';
import 'css_border_detail.dart';

/// 画某一行上的行内盒子，分页片段只用自己的行号，避免跨页重复或遗漏。
void paintInlineBoxes(
  Canvas canvas,
  MeasuredBlock block,
  int from,
  int to,
  double top,
  double width,
  ReadingTheme theme, {
  BookImageLookup? images,
  BookShadowPainter paintShadows = paintBookShadows,
}) {
  if (block.inlineBoxes.isEmpty) return;
  for (var line = from; line < to; line++) {
    for (final span in block.inlineBoxes.where((b) => b.line == line)) {
      paintBookBoxRect(
        canvas,
        span.rect.shift(
          Offset(block.inset + block.horizontalOffset(line, width), top),
        ),
        span.box,
        theme,
        leftEdge: span.first,
        rightEdge: span.last,
        images: images,
        paintShadows: paintShadows,
      );
    }
    top += block.lines[line].height;
  }
}

/// 块级容器与行内装饰共用背景、边框和阴影的画法。
void paintBookBoxRect(
  Canvas canvas,
  Rect rect,
  BlockBox box,
  ReadingTheme theme, {
  bool topEdge = true,
  bool bottomEdge = true,
  bool leftEdge = true,
  bool rightEdge = true,
  BookImageLookup? images,
  Rect? backgroundArea,
  Rect? topBorderGap,
  BookShadowPainter paintShadows = paintBookShadows,
}) {
  final top = topEdge ? box.borderTop : 0.0;
  final left = leftEdge ? box.borderLeft : 0.0;
  final right = rightEdge ? box.borderRight : 0.0;
  final bottom = bottomEdge ? box.borderBottom : 0.0;
  final whole = topEdge && bottomEdge && leftEdge && rightEdge;
  // 只在元素真实边缘画对应的角；跨页中段不凭空产生圆弧。
  final corners = box.cornersIn((backgroundArea ?? rect).size);
  final shape = BorderRadius.only(
    topLeft: topEdge && leftEdge ? corners.topLeft : Radius.zero,
    topRight: topEdge && rightEdge ? corners.topRight : Radius.zero,
    bottomRight: bottomEdge && rightEdge ? corners.bottomRight : Radius.zero,
    bottomLeft: bottomEdge && leftEdge ? corners.bottomLeft : Radius.zero,
  ).toRRect(rect).scaleRadii();

  if (box.shadows.isNotEmpty) {
    if (whole) {
      paintShadows(canvas, shape, box.shadows);
    } else {
      // 把切口外的假边推过模糊范围，再裁回本片。真实边和圆角沿用整框画法。
      var halo = 1.0;
      for (final shadow in box.shadows) {
        halo = math.max(
          halo,
          shadow.spreadRadius.abs() +
              2 * shadow.blurRadius +
              math.max(shadow.offset.dx.abs(), shadow.offset.dy.abs()) +
              2,
        );
      }
      final extended = RRect.fromRectAndCorners(
        Rect.fromLTRB(
          rect.left - (leftEdge ? 0 : halo),
          rect.top - (topEdge ? 0 : halo),
          rect.right + (rightEdge ? 0 : halo),
          rect.bottom + (bottomEdge ? 0 : halo),
        ),
        topLeft: shape.tlRadius,
        topRight: shape.trRadius,
        bottomLeft: shape.blRadius,
        bottomRight: shape.brRadius,
      );
      canvas.save();
      canvas.clipRect(
        Rect.fromLTRB(
          rect.left - (leftEdge ? halo : 0),
          rect.top - (topEdge ? halo : 0),
          rect.right + (rightEdge ? halo : 0),
          rect.bottom + (bottomEdge ? halo : 0),
        ),
        doAntiAlias: false,
      );
      paintShadows(canvas, extended, box.shadows);
      canvas.restore();
    }
  }
  final background = box.background;
  if (background != null) {
    canvas.drawRRect(
      shape,
      Paint()..color = adaptSurface(background, theme.background),
    );
  }
  if (box.backgroundImage case final image?) {
    canvas.save();
    canvas.clipRRect(shape);
    final positioning = backgroundArea ?? rect;
    paintCssBackground(
      canvas,
      rect,
      Rect.fromLTRB(
        positioning.left + box.borderLeft,
        positioning.top + box.borderTop,
        positioning.right - box.borderRight,
        positioning.bottom - box.borderBottom,
      ),
      image,
      images,
    );
    canvas.restore();
  }

  if (top <= 0 && bottom <= 0 && left <= 0 && right <= 0) return;
  // 题签遮住的只有上边线，底图与边框的其它三边仍正常绘制。
  if (topBorderGap != null) {
    canvas.save();
    canvas.clipPath(
      Path()
        ..fillType = PathFillType.evenOdd
        ..addRect(canvas.getLocalClipBounds())
        ..addRect(
          Rect.fromLTRB(
            topBorderGap.left,
            rect.top,
            topBorderGap.right,
            rect.top + top,
          ),
        ),
    );
  }
  try {
    // 四条边各用各的颜色；夜间适配也逐边做，不能先合成一个颜色。
    final colors = [
      for (final color in box.borderColors)
        adaptBorder(color, theme.background),
    ];
    final styles = box.borderStyles;
    int styleOf(int side) => styles.length > side ? styles[side] : 1;
    final solid =
        styleOf(0) == 1 &&
        styleOf(1) == 1 &&
        styleOf(2) == 1 &&
        styleOf(3) == 1;
    final sameColor = colors.every((color) => color == colors.first);
    if (box.radius > 0 &&
        solid &&
        sameColor &&
        (left == right) &&
        top > 0 &&
        bottom > 0 &&
        left == box.borderTop) {
      // 四边颜色、宽度、线型都一致且整块在本页：直接描一圈圆角矩形
      canvas.drawDRRect(
        shape,
        shape.deflate(left),
        Paint()..color = colors.first,
      );
      return;
    }
    if (box.radius > 0) {
      paintRoundedCssBorders(
        canvas,
        shape,
        [top, right, bottom, left],
        styles,
        colors,
      );
      return;
    }
    void side(Rect area, int side) =>
        paintStraightCssBorder(canvas, area, side, styleOf(side), colors[side]);

    canvas.save();
    canvas.clipRRect(shape);
    if (top > 0) {
      side(Rect.fromLTWH(rect.left, rect.top, rect.width, top), 0);
    }
    if (bottom > 0) {
      side(
        Rect.fromLTWH(rect.left, rect.bottom - bottom, rect.width, bottom),
        2,
      );
    }
    if (left > 0) {
      side(Rect.fromLTWH(rect.left, rect.top, left, rect.height), 3);
    }
    if (right > 0) {
      side(Rect.fromLTWH(rect.right - right, rect.top, right, rect.height), 1);
    }
    canvas.restore();
  } finally {
    if (topBorderGap != null) canvas.restore();
  }
}

/// 块盒子和表格共用书内边线的线型。
void paintStraightCssBorder(
  Canvas canvas,
  Rect area,
  int side,
  int style,
  Color color,
) {
  if (area.width <= 0 || area.height <= 0) return;
  final paint = Paint()..color = color;
  if (style >= 4) {
    paintCssBorderDetail(canvas, area, side, style, color);
    return;
  }
  if (style == 1) {
    canvas.drawRect(area, paint);
    return;
  }
  final horizontal = side == 0 || side == 2;
  final length = horizontal ? area.width : area.height;
  final thickness = horizontal ? area.height : area.width;
  // 滚动时框可能跨整章。保留从框顶开始的虚线节奏，只生成当前画布能看到的几段。
  final visible = area.intersect(canvas.getLocalClipBounds());
  if (visible.isEmpty) return;
  final start = horizontal ? visible.left - area.left : visible.top - area.top;
  final stop = horizontal
      ? visible.right - area.left
      : visible.bottom - area.top;
  if (style == 3) {
    // dotted 是圆点，直径等于边框宽度；矩形小段在细线时会变成近乎连续的暗带。
    final step = thickness * 2;
    for (
      var offset = (start / step).floor() * step + thickness / 2;
      offset < length && offset - thickness / 2 < stop;
      offset += step
    ) {
      canvas.drawCircle(
        horizontal
            ? Offset(area.left + offset, area.center.dy)
            : Offset(area.center.dx, area.top + offset),
        thickness / 2,
        paint,
      );
    }
    return;
  }
  final dash = thickness * 3.2;
  final gap = thickness * 2.2;
  var offset = (start / (dash + gap)).floor() * (dash + gap);
  while (offset < stop) {
    final end = (offset + dash).clamp(0.0, length);
    canvas.drawRect(
      horizontal
          ? Rect.fromLTWH(area.left + offset, area.top, end - offset, thickness)
          : Rect.fromLTWH(
              area.left,
              area.top + offset,
              thickness,
              end - offset,
            ),
      paint,
    );
    offset = end + gap;
  }
}
