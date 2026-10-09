import 'dart:ui' show BoxHeightStyle, BoxWidthStyle;

import 'package:flutter/painting.dart';

/// Flutter 字距会在行首、行尾各留半份。两端对齐只把空档放在字符之间。
/// 绘制、选择框、命中和光标统一平移，外部仍使用同一套 TextPainter 坐标。
class EdgeAlignedTextPainter extends TextPainter {
  EdgeAlignedTextPainter({
    required super.text,
    required super.textScaler,
    required this.spacing,
  }) : super(textDirection: TextDirection.ltr);

  final double spacing;

  @override
  double get width => super.width - spacing;

  @override
  void paint(Canvas canvas, Offset offset) =>
      super.paint(canvas, offset - Offset(spacing / 2, 0));

  @override
  TextPosition getPositionForOffset(Offset offset) =>
      super.getPositionForOffset(offset + Offset(spacing / 2, 0));

  @override
  Offset getOffsetForCaret(TextPosition position, Rect caretPrototype) {
    final offset = super.getOffsetForCaret(position, caretPrototype);
    if (position.offset == 0) return Offset(0, offset.dy);
    if (position.offset == plainText.length) return Offset(width, offset.dy);
    return offset - Offset(spacing / 2, 0);
  }

  @override
  List<TextBox> getBoxesForSelection(
    TextSelection selection, {
    BoxHeightStyle boxHeightStyle = BoxHeightStyle.tight,
    BoxWidthStyle boxWidthStyle = BoxWidthStyle.tight,
  }) => [
    for (final box in super.getBoxesForSelection(
      selection,
      boxHeightStyle: boxHeightStyle,
      boxWidthStyle: boxWidthStyle,
    ))
      TextBox.fromLTRBD(
        (box.left - spacing / 2).clamp(0, width),
        box.top,
        (box.right - spacing / 2).clamp(0, width),
        box.bottom,
        box.direction,
      ),
  ];

  @override
  List<LineMetrics> computeLineMetrics() => [
    for (final line in super.computeLineMetrics())
      LineMetrics(
        hardBreak: line.hardBreak,
        ascent: line.ascent,
        descent: line.descent,
        unscaledAscent: line.unscaledAscent,
        height: line.height,
        width: line.width - spacing,
        left: line.left,
        baseline: line.baseline,
        lineNumber: line.lineNumber,
      ),
  ];
}
