import 'package:flutter/painting.dart';

import '../../../../engine/layout/chapter_paginator.dart';
import '../../../../engine/layout/layout_options.dart';

void paintTableFragments(
  Canvas canvas,
  List<PageFragment> fragments,
  LayoutOptions options,
  Color text,
  Color rule,
) {
  for (final fragment in fragments) {
    final block = fragment.block;
    if (fragment.tableFrame case final frame?) {
      if (block.tableHeader) {
        canvas.drawRect(frame, Paint()..color = rule.withValues(alpha: .08));
      }
      canvas.drawRect(
        frame,
        Paint()
          ..color = rule.withValues(alpha: .3)
          ..style = PaintingStyle.stroke
          ..strokeWidth = .7,
      );
    }
    if (fragment.frameOnly || block.imageSize != null) continue;
    var y = fragment.y;
    for (var line = fragment.lineFrom; line < fragment.lineTo; line++) {
      final painter = block.createSingleLinePainter(
        lineIndex: line,
        textScaler: options.textScaler,
        color: text,
      );
      painter.paint(canvas, Offset(block.inset, y));
      painter.dispose();
      y += block.lines[line].height;
    }
  }
}
