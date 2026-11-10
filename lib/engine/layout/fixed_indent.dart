import 'package:flutter/painting.dart';

/// 原文坐标仍沿用两个占位字符，绘制副本改用按字号排宽的EM SPACE。
/// U+3000在部分字体中是半角甚至零宽；U+2003由排版引擎按1em处理。
abstract final class FixedIndent {
  static String display(String prefix) => prefix.replaceAll('\u3000', '\u2003');

  static TextSpan span(String prefix, TextStyle style) => TextSpan(
    text: display(prefix),
    style: style.copyWith(letterSpacing: 0, wordSpacing: 0),
  );
}
