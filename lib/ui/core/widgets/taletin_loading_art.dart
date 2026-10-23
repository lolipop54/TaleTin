import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 共用原图和笔触遮罩；扫描只改变明暗，不移动或重画图案。
abstract final class TaleTinLoadingArt {
  static ui.Image? image;
  static late ui.Image inkMask;
  static Future<void>? _preparing;

  /// 首页释放首帧前完成解码和遮罩准备，动画中不再处理原图像素。
  static Future<void> prepare({String assetPrefix = ''}) =>
      _preparing ??= _load(assetPrefix);

  static Future<void> _load(String assetPrefix) async {
    final data = await rootBundle.load(
      '${assetPrefix}assets/pics/loading_icon.png',
    );
    final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
    try {
      final original = (await codec.getNextFrame()).image;
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawImage(
        original,
        Offset.zero,
        Paint()
          // 白底变透明，灰度转换成笔触覆盖率，保留导出图的柔和边缘。
          ..colorFilter = const ColorFilter.matrix([
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            -1,
            0,
            0,
            0,
            255,
          ]),
      );
      final picture = recorder.endRecording();
      try {
        inkMask = await picture.toImage(original.width, original.height);
        // 两张图都准备好才发布就绪，避免首次出现时闪一下空白。
        image = original;
      } finally {
        picture.dispose();
      }
    } finally {
      codec.dispose();
    }
  }
}

class TaleTinLoadingPainter extends CustomPainter {
  TaleTinLoadingPainter(this.scan, this.color) : super(repaint: scan);

  final Animation<double> scan;
  final Color color;

  // 与已确认的扫描预览一致：中心25%笔触强度，边缘柔和回到100%。
  static const _stops = [0.0, .15, .35, .5, .65, .85, 1.0];
  static const _strengths = [1.0, .96, .55, .25, .55, .96, 1.0];

  @override
  void paint(Canvas canvas, Size size) {
    final image = TaleTinLoadingArt.image;
    if (image == null) return;
    final bounds = Offset.zero & size;
    // 原预览以480px绘制：中心从-90走到570、半宽85。
    // 两端的亮带都在图标外，因此重复播放以及停在0时没有明暗跳变。
    final center = (-90 + 660 * scan.value) / 480 * size.width;
    final halfWidth = 85 / 480 * size.width;
    final gradient = ui.Gradient.linear(
      Offset(center - halfWidth, 0),
      Offset(center + halfWidth, 0),
      [
        for (final strength in _strengths)
          color.withValues(alpha: color.a * strength),
      ],
      _stops,
    );
    // 小范围离屏合成把渐变限定在原有笔触内，绝不改变图案坐标。
    canvas.saveLayer(bounds, Paint());
    canvas.drawImageRect(
      TaleTinLoadingArt.inkMask,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      bounds,
      Paint()..filterQuality = FilterQuality.medium,
    );
    canvas.drawRect(
      bounds,
      Paint()
        ..shader = gradient
        ..blendMode = BlendMode.srcIn,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(TaleTinLoadingPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.scan != scan;
}
