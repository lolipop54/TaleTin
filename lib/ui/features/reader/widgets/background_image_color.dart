import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

/// 只在准备阶段采样小图，供页眉、页脚和文字计算对比度，不逐帧读取像素。
Future<Color> averageBackgroundColor(
  Size size,
  void Function(Canvas) draw,
) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder)..scale(8 / size.width, 8 / size.height);
  draw(canvas);
  final picture = recorder.endRecording(), small = await picture.toImage(8, 8);
  picture.dispose();
  final data = await small.toByteData(format: ui.ImageByteFormat.rawRgba);
  small.dispose();
  var r = 0.0, g = 0.0, b = 0.0, a = 0.0;
  for (var i = 0; i < 256; i += 4) {
    final alpha = data!.getUint8(i + 3) / 255;
    r += data.getUint8(i) * alpha;
    g += data.getUint8(i + 1) * alpha;
    b += data.getUint8(i + 2) * alpha;
    a += alpha;
  }
  return a == 0
      ? const Color(0x00000000)
      : Color.from(
          alpha: a / 64,
          red: r / a / 255,
          green: g / a / 255,
          blue: b / a / 255,
        );
}
