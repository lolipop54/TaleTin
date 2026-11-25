import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'scan_frames.dart';

/// 两页始终使用同一画布坐标，仅改变下一页的裁剪高度。
class ScanFramesPainter extends CustomPainter {
  const ScanFramesPainter({
    required this.frames,
    required this.progress,
    required this.bounds,
    required this.paper,
    required this.line,
    this.frameBounds,
    this.columns = 1,
  });
  final ScanFrames frames;
  final double progress;
  final Rect bounds;
  final Rect? frameBounds;
  final int columns;
  final Color paper, line;

  /// 正文和独立更新的页脚使用同一条扫描边界。
  Path get revealed {
    final step = progress * columns;
    final column = step.floor().clamp(0, columns - 1);
    final width = bounds.width / columns;
    final left = bounds.left + width * column;
    final y = bounds.top + bounds.height * (step - column);
    return Path()
      ..addRect(Rect.fromLTRB(bounds.left, bounds.top, left, bounds.bottom))
      ..addRect(Rect.fromLTRB(left, bounds.top, left + width, y));
  }

  @override
  void paint(Canvas canvas, Size size) {
    void image(ui.Image source) => canvas.drawImageRect(
      source,
      Rect.fromLTWH(0, 0, source.width.toDouble(), source.height.toDouble()),
      frameBounds ?? Offset.zero & size,
      Paint()..filterQuality = FilterQuality.none,
    );
    canvas.drawColor(paper, BlendMode.src);
    image(frames.current);
    // 两张图已包含各自页眉、正文和页脚；扫描整页，不能再覆盖回当前页信息。
    if (frames.next case final next?) {
      canvas.save();
      // 已扫完的左列保持目标页，只在当前列内从上往下推进。
      canvas.clipPath(revealed);
      image(next);
      canvas.restore();
    }
    paintLine(canvas);
  }

  void paintLine(Canvas canvas) {
    final step = progress * columns;
    final column = step.floor().clamp(0, columns - 1);
    final width = bounds.width / columns;
    final left = bounds.left + width * column;
    final y = bounds.top + bounds.height * (step - column);
    if (progress > 0 && progress < 1) {
      canvas.drawLine(
        Offset(left, y),
        Offset(left + width, y),
        Paint()
          ..color = line
          ..strokeWidth = 1,
      );
    }
  }

  @override
  bool shouldRepaint(ScanFramesPainter old) =>
      frames != old.frames ||
      progress != old.progress ||
      bounds != old.bounds ||
      frameBounds != old.frameBounds ||
      paper != old.paper ||
      line != old.line ||
      columns != old.columns;
}
