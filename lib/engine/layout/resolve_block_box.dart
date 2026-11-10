import 'dart:math' as math;

import 'package:flutter/painting.dart';

import '../styles/computed_style.dart';
import '../styles/property_parsers.dart';
import '../styles/style_box_value.dart';
import '../styles/style_value.dart';
import 'measured_text_geometry.dart';
import 'background_image_style.dart';

/// 长度直到这里才结合字号、容器宽度解析；不得经过旧的百分之一 em 数组。
BlockBox? resolveBlockBox(BoxStyleSpec style, LengthContext context) {
  if (style.isEmpty) return null;
  double px(Length? value) =>
      value == null || value.isAuto ? 0 : value.resolve(context);
  double border(BorderSideSpec? side) {
    if (side == null || !side.isVisible) return 0;
    final width = px(side.width);
    // Chromium 的实际边框宽度取整，不足1px的非零边框仍占1px。
    // 测量和绘制一起使用该宽度，避免细点线因多次亚像素混色几乎消失。
    return width <= 0 ? 0 : math.max(1, width.floorToDouble());
  }

  int line(BorderSideSpec? side) => switch (side?.style) {
    BorderLineStyle.dashed => 2,
    BorderLineStyle.dotted => 3,
    BorderLineStyle.double => 4,
    BorderLineStyle.groove => 5,
    BorderLineStyle.ridge => 6,
    BorderLineStyle.inset => 7,
    BorderLineStyle.outset => 8,
    _ => 1,
  };
  final b = style.border, p = style.padding, r = style.radii;
  // 每条边用自己的颜色：书里「上边浅灰、左边深色」时不能用同一个颜色画四边。
  // 没写颜色的边按引擎历史默认的灰色（见 kDefaultBorderColor），不再从别的边
  // 借颜色；完全没写边框的边保持透明。
  Color colorOf(BorderSideSpec? side) {
    if (side == null || border(side) <= 0) return const Color(0x00000000);
    return Color(side.color?.argb ?? kDefaultBorderColor.argb);
  }

  return BlockBox(
    backgroundImage: BookBackgroundImage.resolve(style.background, context),
    background: style.background?.color?.argb == null
        ? null
        : Color(style.background!.color!.argb),
    borderColors: [
      colorOf(b?.top),
      colorOf(b?.right),
      colorOf(b?.bottom),
      colorOf(b?.left),
    ],
    borderTop: border(b?.top),
    borderRight: border(b?.right),
    borderBottom: border(b?.bottom),
    borderLeft: border(b?.left),
    borderStyles: [
      line(b?.top),
      line(b?.right),
      line(b?.bottom),
      line(b?.left),
    ],
    borderRadius: BorderRadius.only(
      topLeft: Radius.circular(math.max(0, px(r?.topLeft))),
      topRight: Radius.circular(math.max(0, px(r?.topRight))),
      bottomRight: Radius.circular(math.max(0, px(r?.bottomRight))),
      bottomLeft: Radius.circular(math.max(0, px(r?.bottomLeft))),
    ),
    shadows: [
      for (final shadow in style.shadow ?? const <ShadowValue>[])
        BoxShadow(
          offset: Offset(px(shadow.offsetX), px(shadow.offsetY)),
          blurRadius: math.max(0, px(shadow.blur)),
          spreadRadius: px(shadow.spread),
          color: Color(shadow.color?.argb ?? 0),
        ),
    ],
    padTop: px(p?.top),
    padRight: px(p?.right),
    padBottom: px(p?.bottom),
    padLeft: px(p?.left),
  );
}
