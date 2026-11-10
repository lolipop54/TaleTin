import 'dart:math' as math;

import 'package:flutter/painting.dart';

import '../../../../engine/layout/chapter_paginator.dart';
import '../../../core/theme/reading_theme.dart';
import 'book_colors.dart';
import 'book_box_paint.dart';

/// 分页和连续滚动共用：hr 自身的完整边框盒只绘制一次。
void paintReaderDivider(
  Canvas canvas,
  Size size,
  PageFragment fragment,
  ReadingTheme theme,
) {
  final block = fragment.block;
  if (block.box case final box? when block.boxId == null) {
    final outerTop = block.bodyTop - box.insetTop;
    final outerBottom = block.bodyBottom - box.insetBottom;
    paintBookBoxRect(
      canvas,
      Rect.fromLTWH(
        block.inset - box.insetLeft,
        fragment.y + outerTop,
        (block.layoutWidth ?? size.width) + box.insetLeft + box.insetRight,
        math.max(0, fragment.height - outerTop - outerBottom),
      ),
      box,
      theme,
    );
    return;
  }
  // 分隔线可能带着外层容器的内边距：线要画在内容区中间，
  // 不能把上下内边距也算进去、让线整体往下偏。
  final contentTop = fragment.y + block.bodyTop;
  final contentHeight = fragment.height - block.bodyTop - block.bodyBottom;
  final y =
      contentTop +
      (contentHeight > 0 ? contentHeight / 2 : fragment.height / 2);
  final line = block.line;
  if (line == null) {
    // 书里没写线型：保留原来的短分隔线
    canvas.drawLine(
      Offset(size.width * 0.3, y),
      Offset(size.width * 0.7, y),
      Paint()
        ..color = theme.secondary.withValues(alpha: 0.35)
        ..strokeWidth = 1,
    );
    return;
  }
  final start = block.inset;
  final end = block.inset + (block.layoutWidth ?? size.width);
  final paint = Paint()
    ..color = adaptBorder(Color(line[2]), theme.background)
    ..strokeWidth = math.max(1.0, line[0].toDouble())
    ..strokeCap = StrokeCap.round;
  final style = line[1];
  if (style == 2) {
    // 虚线
    const dash = 6.0, gap = 4.0;
    for (var x = start; x < end; x += dash + gap) {
      canvas.drawLine(Offset(x, y), Offset(math.min(x + dash, end), y), paint);
    }
  } else if (style == 3) {
    // 点线
    final step = math.max(3.0, paint.strokeWidth * 2.4);
    for (var x = start; x <= end; x += step) {
      canvas.drawCircle(Offset(x, y), paint.strokeWidth * 0.55, paint);
    }
  } else {
    canvas.drawLine(Offset(start, y), Offset(end, y), paint);
  }
}
