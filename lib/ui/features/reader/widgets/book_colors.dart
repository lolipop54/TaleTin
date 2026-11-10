/// 书内样式的颜色在阅读主题上的落地。
///
/// 原则：书里写了的颜色优先（用户要求贴近原书）；但夜间主题下黑色文字、
/// 白色底框会直接看不见或刺眼，这时按亮度翻转，保证能读。书里没写的
/// 颜色继续用阅读主题。
library;

import 'package:flutter/painting.dart' show Color, HSLColor;

/// 相对亮度（sRGB 近似），用于比较对比度。
double _luminance(Color color) => color.computeLuminance();

double _contrast(Color a, Color b) {
  final la = _luminance(a);
  final lb = _luminance(b);
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

/// 文字颜色：与原书一致；与纸面对比度不足时翻转亮度，仍不行就用主题色。
Color adaptInk(Color ink, Color paper, Color fallback) {
  if (ink.a == 0) return fallback;
  if (_contrast(ink, paper) >= 2.2) return ink;
  final flipped = _flipLightness(ink);
  if (_contrast(flipped, paper) >= 2.2) return flipped;
  return fallback;
}

/// 背景色：与原书一致；只有夜间主题下把浅色底压暗，避免整块发亮。
///
/// 浅色主题不再“提亮深色底”：原书里的深红、深蓝标题块就该是那个颜色，
/// 提亮会被读成一块淡粉色，与原书差别很大（真机对照发现）。
Color adaptSurface(Color surface, Color paper) {
  if (surface.a == 0) return surface.withValues(alpha: 0);
  final paperDark = _luminance(paper) < 0.35;
  final surfaceLight = _luminance(surface) > 0.55;
  if (paperDark && surfaceLight) {
    // 压暗到与纸面接近的亮度，保留一点原色相
    return Color.alphaBlend(
      surface.withValues(alpha: 0.14),
      paper,
    );
  }
  return surface;
}

/// 边框颜色：浅色主题照书里的颜色（书里的浅灰细线本来就该很淡）；
/// 只有夜间主题下、与纸面几乎看不见时才翻转亮度。
Color adaptBorder(Color border, Color paper) {
  if (_luminance(paper) >= 0.35) return border;
  final contrast = _contrast(border, paper);
  if (contrast >= 1.6) return border;
  return _flipLightness(border).withValues(alpha: border.a);
}

/// 阴影颜色：夜间主题下阴影几乎不可见，保留原值即可。
Color adaptShadow(Color shadow) => shadow;

Color _flipLightness(Color color) {
  final hsl = HSLColor.fromColor(color);
  return hsl.withLightness((1 - hsl.lightness).clamp(0.0, 1.0)).toColor();
}
