import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'scan_frames.dart';

/// 两页始终使用同一画布坐标，仅改变下一页的裁剪高度。
class ScanFramesPainter extends CustomPainter {
  const ScanFramesPainter({required this.frames, required this.progress,
    required this.bounds, required this.paper, required this.line, this.frameBounds});
  final ScanFrames frames;
  final double progress;
  final Rect bounds;
  final Rect? frameBounds;
  final Color paper, line;

  @override
  void paint(Canvas canvas, Size size) {
    void image(ui.Image source) => canvas.drawImageRect(source,
      Rect.fromLTWH(0, 0, source.width.toDouble(), source.height.toDouble()),
      frameBounds ?? Offset.zero & size, Paint()..filterQuality = FilterQuality.none);
    canvas.drawColor(paper, BlendMode.src);
    image(frames.current);
    // 两张图已包含各自页眉、正文和页脚；扫描整页，不能再覆盖回当前页信息。
    final y = bounds.top + bounds.height * progress;
    if (frames.next case final next?) {
      canvas.save();
      canvas.clipRect(Rect.fromLTRB(bounds.left, bounds.top, bounds.right, y));
      image(next);
      canvas.restore();
    }
    if (progress > 0 && progress < 1) {
      canvas.drawLine(Offset(bounds.left, y), Offset(bounds.right, y),
        Paint()..color = line..strokeWidth = 1);
    }
  }

  @override
  bool shouldRepaint(ScanFramesPainter old) => frames != old.frames ||
      progress != old.progress || bounds != old.bounds || frameBounds != old.frameBounds ||
      paper != old.paper || line != old.line;
}
