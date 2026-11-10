import 'dart:ui';

import 'measured_text_geometry.dart';

/// 公式作为 SVG 整体选取；范围使用原文字坐标，不插入占位字符。
extension FormulaSelection on InlineImagePlacement {
  Iterable<Rect> selectedRects(int start, int end) sync* {
    final stop = formula?.end ?? offset + 1;
    if (offset < end && stop > start) yield Offset.zero & size;
  }

  int offsetAt(Offset point) =>
      formula != null && point.dx > size.width / 2 ? formula!.end : offset;
  Rect caretRect(int position, bool atEnd) => Rect.fromLTWH(
    formula == null
        ? (atEnd ? size.width : 0)
        : (position <= offset ? 0 : size.width),
    0,
    0,
    size.height,
  );
}
