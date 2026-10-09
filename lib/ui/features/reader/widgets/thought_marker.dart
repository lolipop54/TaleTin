import 'package:flutter/material.dart';

/// 不插入正文字符，避免标记改变断行、分页及已有位置。
Rect thoughtMarkerRect(Rect lastLine, double pageWidth) => Rect.fromLTWH(
  (lastLine.right + 2).clamp(0, pageWidth - 18),
  (lastLine.top - 4).clamp(0, double.infinity),
  16,
  16,
);

class PageThoughtMarker {
  const PageThoughtMarker({
    required this.id,
    required this.rect,
    required this.color,
  });
  final String id;
  final Rect rect;
  final Color color;
}

void paintThoughtMarker(Canvas canvas, Rect rect, Color color) {
  final shape = Path()
    ..addRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(rect.left, rect.top, 16, 12),
        const Radius.circular(2),
      ),
    )
    ..moveTo(rect.left + 3, rect.top + 11)
    ..lineTo(rect.left + 3, rect.bottom)
    ..lineTo(rect.left + 8, rect.top + 11)
    ..close();
  canvas.drawPath(shape, Paint()..color = color);
  final lines = Paint()
    ..color = Colors.white
    ..strokeWidth = 1.3;
  for (final y in [4.0, 8.0]) {
    canvas.drawLine(
      Offset(rect.left + 4, rect.top + y),
      Offset(rect.right - 4, rect.top + y),
      lines,
    );
  }
}
