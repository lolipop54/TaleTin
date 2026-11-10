import 'package:flutter/painting.dart';

import '../../../../engine/layout/measured_block.dart';
import '../../../core/theme/reading_theme.dart';
import 'book_colors.dart';
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
}) {
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
}) {
  final top = topEdge ? box.borderTop : 0.0;
  final left = leftEdge ? box.borderLeft : 0.0;
  final right = rightEdge ? box.borderRight : 0.0;
  final bottom = bottomEdge ? box.borderBottom : 0.0;
  final whole = topEdge && bottomEdge && leftEdge && rightEdge;
  // 只在元素真实边缘画对应的角；跨页中段不凭空产生圆弧。
  final corners = box.borderRadius;
  final shape = BorderRadius.only(
    topLeft: topEdge && leftEdge ? corners.topLeft : Radius.zero,
    topRight: topEdge && rightEdge ? corners.topRight : Radius.zero,
    bottomRight: bottomEdge && rightEdge ? corners.bottomRight : Radius.zero,
    bottomLeft: bottomEdge && leftEdge ? corners.bottomLeft : Radius.zero,
  ).toRRect(rect).scaleRadii();

  if (whole && box.shadows.isNotEmpty) {
    // 外阴影只在盒子外部可见，透明背景不能被阴影涂成实心灰块。
    canvas.save();
    canvas.clipPath(
      Path.combine(
        PathOperation.difference,
        Path()..addRect(rect.inflate(1000)),
        Path()..addRRect(shape),
      ),
    );
    for (final shadow in box.shadows) {
      canvas.drawRRect(
        shape.inflate(shadow.spreadRadius).shift(shadow.offset),
        Paint()
          ..color = shadow.color
          ..maskFilter = shadow.blurRadius > 0
              ? MaskFilter.blur(BlurStyle.normal, shadow.blurRadius / 2)
              : null,
      );
    }
    canvas.restore();
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

  // 四条边各用各的颜色；夜间适配也逐边做，不能先合成一个颜色。
  final colors = [
    for (final color in box.borderColors) adaptBorder(color, theme.background),
  ];
  final paints = [for (final color in colors) Paint()..color = color];
  final styles = box.borderStyles;
  int styleOf(int side) => styles.length > side ? styles[side] : 1;
  final solid =
      styleOf(0) == 1 && styleOf(1) == 1 && styleOf(2) == 1 && styleOf(3) == 1;
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
  // 每条边按书里的线型画：实线整段，虚线／点线切成小段
  void side(Rect area, int side) {
    if (area.width <= 0 || area.height <= 0) return;
    final style = styleOf(side);
    final paint = paints[side];
    if (style >= 4) {
      paintCssBorderDetail(canvas, area, side, style, colors[side]);
      return;
    }
    if (style == 1) {
      canvas.drawRect(area, paint);
      return;
    }
    final horizontal = side == 0 || side == 2;
    final length = horizontal ? area.width : area.height;
    final thickness = horizontal ? area.height : area.width;
    if (style == 3) {
      // dotted 是圆点，直径等于边框宽度；矩形小段在细线时会变成近乎连续的暗带。
      for (
        var offset = thickness / 2;
        offset < length;
        offset += thickness * 2
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
    var offset = 0.0;
    while (offset < length) {
      final end = (offset + dash).clamp(0.0, length);
      canvas.drawRect(
        horizontal
            ? Rect.fromLTWH(
                area.left + offset,
                area.top,
                end - offset,
                thickness,
              )
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

  canvas.save();
  canvas.clipRRect(shape);
  if (top > 0) {
    side(Rect.fromLTWH(rect.left, rect.top, rect.width, top), 0);
  }
  if (bottom > 0) {
    side(Rect.fromLTWH(rect.left, rect.bottom - bottom, rect.width, bottom), 2);
  }
  if (left > 0) {
    side(Rect.fromLTWH(rect.left, rect.top, left, rect.height), 3);
  }
  if (right > 0) {
    side(Rect.fromLTWH(rect.right - right, rect.top, right, rect.height), 1);
  }
  canvas.restore();
}
