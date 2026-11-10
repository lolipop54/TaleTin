import 'dart:ui' show BoxHeightStyle, BoxWidthStyle;

import 'package:flutter/painting.dart';

/// 两端对齐只把空档放在字符之间。整行都有字距时去掉两侧各半份留白，
/// 固定缩进开头的行只去掉行尾留白；绘制、选区、命中和光标使用相同坐标。
class EdgeAlignedTextPainter extends TextPainter {
  EdgeAlignedTextPainter({
    required super.text,
    required super.textScaler,
    required this.spacing,
    this.fixedPrefixLength = 0,
  }) : super(textDirection: TextDirection.ltr);

  final double spacing;
  final int fixedPrefixLength;

  // 前缀不设字距时，Flutter 把正文的多余边缘字距留在行尾。此时若像普通
  // 整行那样左移半份字距，会把实际字形移进缩进区，并让右边缘同时留白。
  double get _edgeShift => fixedPrefixLength > 0 ? 0 : spacing / 2;

  // 只有缩进的文字片段没有参与拉伸的字符，也没有要扣掉的行尾字距。
  double get _trailingSpacing =>
      fixedPrefixLength >= plainText.length ? 0 : spacing;

  double get _prefixWidth => fixedPrefixLength == 0
      ? 0
      : super
            .getOffsetForCaret(
              TextPosition(offset: fixedPrefixLength),
              Rect.zero,
            )
            .dx;

  @override
  double get width => super.width - _trailingSpacing;

  @override
  void paint(Canvas canvas, Offset offset) {
    bool decorated(InlineSpan? span) =>
        span is TextSpan &&
        (span.style?.decoration != null ||
            (span.children?.any(decorated) ?? false));
    if (!decorated(text)) {
      super.paint(canvas, offset - Offset(_edgeShift, 0));
      return;
    }
    // Flutter 的下划线包含两侧的额外字距；字形已经按边缘校准后，
    // 装饰线仍可能伸出内容区。只收住这段装饰的横向范围。
    canvas.save();
    canvas.clipRect(
      Rect.fromLTRB(
        offset.dx,
        offset.dy - 1000,
        offset.dx + width,
        offset.dy + height + 1000,
      ),
    );
    super.paint(canvas, offset - Offset(_edgeShift, 0));
    canvas.restore();
  }

  @override
  TextPosition getPositionForOffset(Offset offset) =>
      super.getPositionForOffset(offset + Offset(_edgeShift, 0));

  @override
  Offset getOffsetForCaret(TextPosition position, Rect caretPrototype) {
    final offset = super.getOffsetForCaret(position, caretPrototype);
    if (position.offset == 0) return Offset(0, offset.dy);
    if (position.offset == plainText.length) return Offset(width, offset.dy);
    if (position.offset <= fixedPrefixLength) return offset;
    return offset - Offset(_edgeShift, 0);
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
        (box.left - _edgeShift).clamp(
          fixedPrefixLength > 0 && selection.start >= fixedPrefixLength
              ? _prefixWidth
              : 0,
          width,
        ),
        box.top,
        (box.right - _edgeShift).clamp(0, width),
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
        width: line.width - _trailingSpacing,
        left: line.left,
        baseline: line.baseline,
        lineNumber: line.lineNumber,
      ),
  ];
}
