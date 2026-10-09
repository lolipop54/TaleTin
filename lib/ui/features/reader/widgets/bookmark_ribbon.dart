import 'package:flutter/material.dart';

import '../../../core/theme/gt_tokens.dart';

/// 静态页、翻页画布与下拉提示共用同一条燕尾书签。
const bookmarkRibbonColor = GtPalette.danger;
const bookmarkRibbonSize = Size(16, 28);
const bookmarkRibbonRight = 18.0;
final bookmarkRibbonSvg =
    '<svg width="16" height="28" viewBox="0 0 16 28" xmlns="http://www.w3.org/2000/svg"><path d="M0 0H16V28L8 22L0 28Z" fill="#${bookmarkRibbonColor.toARGB32().toRadixString(16).substring(2)}"/></svg>';

class BookmarkRibbonPainter extends CustomPainter {
  const BookmarkRibbonPainter({this.outline = false});
  final bool outline;
  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..lineTo(size.width, 0)
      ..lineTo(size.width, size.height)
      ..lineTo(size.width / 2, size.height - 6)
      ..lineTo(0, size.height)
      ..close();
    if (!outline) {
      canvas.drawShadow(path, GtPalette.inverseBackground.withValues(alpha: .3), 1, false);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = bookmarkRibbonColor
        ..style = outline ? PaintingStyle.stroke : PaintingStyle.fill
        ..strokeWidth = 1.5,
    );
  }

  @override
  bool shouldRepaint(BookmarkRibbonPainter old) => old.outline != outline;
}
