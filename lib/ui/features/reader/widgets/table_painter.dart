import 'package:flutter/painting.dart';

import '../../../../engine/layout/chapter_paginator.dart';
import '../../../../engine/layout/layout_options.dart';
import '../../../core/theme/reading_theme.dart';
import 'reader_text_painter.dart';
import 'css_background_paint.dart';

void paintTableFragments(
  Canvas canvas,
  List<PageFragment> fragments,
  LayoutOptions options,
  Color text,
  Color rule, {
  ReadingTheme? theme,
  BookImageLookup? images,
  Color? backdrop,
}) {
  for (final fragment in fragments) {
    final block = fragment.block;
    if (fragment.tableFrame case final frame?) {
      if (block.tableHeader) {
        canvas.drawRect(frame, Paint()..color = rule.withValues(alpha: .08));
      }
      paintTableFrame(canvas, fragment, rule);
    }
    if (fragment.frameOnly || block.imageSize != null) continue;
    ReaderTextPainter(
      options,
      theme ?? ReadingTheme.paper,
      images: images,
      backgroundColor: backdrop,
    ).paint(
      canvas,
      Size(options.contentWidth, options.contentHeight),
      fragment,
    );
  }
}

/// 跨页单元格只画实际存在的边；页尾切片不是单元格的底部。
void paintTableFrame(Canvas canvas, PageFragment fragment, Color rule) {
  final rect = fragment.tableFrame!;
  final path = Path()
    ..moveTo(rect.left, rect.top)
    ..lineTo(rect.left, rect.bottom)
    ..moveTo(rect.right, rect.top)
    ..lineTo(rect.right, rect.bottom);
  if (fragment.tableTopEdge) {
    path
      ..moveTo(rect.left, rect.top)
      ..lineTo(rect.right, rect.top);
  }
  if (fragment.tableBottomEdge) {
    path
      ..moveTo(rect.left, rect.bottom)
      ..lineTo(rect.right, rect.bottom);
  }
  canvas.drawPath(
    path,
    Paint()
      ..color = rule.withValues(alpha: .3)
      ..style = PaintingStyle.stroke
      ..strokeWidth = .7,
  );
}
