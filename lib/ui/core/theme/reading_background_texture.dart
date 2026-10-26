import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../../../domain/models/reading_background.dart';

/// 一次准备的图片同时供 Flutter 画纸面、WebView 的本地图片请求使用。
/// WebView 只收到短地址，不在每次排版、主题签名中重复传输整张图片。
class ReadingBackgroundTexture {
  ReadingBackgroundTexture._(this.id, this.image, this._bytes) {
    (_registered[id] ??= <ReadingBackgroundTexture>[]).add(this);
  }
  final String id;
  final ui.Image image;
  bool disposed = false;
  final Uint8List _bytes;
  String get url => 'https://gtbook.internal/__gt_backgrounds/$id';
  static final _registered = <String, List<ReadingBackgroundTexture>>{};
  static Uint8List? bytesFor(Uri uri) =>
      uri.path.startsWith('/__gt_backgrounds/')
      ? _registered[uri.pathSegments.last]?.lastOrNull?._bytes
      : null;

  static Future<ReadingBackgroundTexture> load(
    ReadingBackground background,
    String root,
  ) async {
    final bytes = background.asset != null
        ? (await rootBundle.load(background.asset!)).buffer.asUint8List()
        : await File(p.join(root, background.path!)).readAsBytes();
    final image = await decodeBackground(bytes);
    return ReadingBackgroundTexture._(background.id, image, bytes);
  }

  void dispose() {
    disposed = true;
    image.dispose();
    final items = _registered[id];
    items?.remove(this);
    if (items?.isEmpty == true) _registered.remove(id);
  }
}

/// 只限制长边，保持源图全部内容；铺纸时再按阅读窗口分别拉伸宽高。
Future<ui.Image> decodeBackground(Uint8List bytes) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  try {
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    final longest = descriptor.width > descriptor.height
        ? descriptor.width
        : descriptor.height;
    final ratio = longest > 2048 ? 2048 / longest : 1.0;
    codec = await descriptor.instantiateCodec(
      targetWidth: (descriptor.width * ratio).round().clamp(1, 2048),
      targetHeight: (descriptor.height * ratio).round().clamp(1, 2048),
    );
    return (await codec.getNextFrame()).image;
  } finally {
    codec?.dispose();
    descriptor?.dispose();
    buffer.dispose();
  }
}

void paintReadingBackground(
  Canvas canvas,
  Size size,
  Color color,
  ui.Image? image,
) {
  canvas.drawRect(Offset.zero & size, Paint()..color = color);
  if (image != null) {
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Offset.zero & size,
      Paint()..filterQuality = FilterQuality.low,
    );
  }
}

class ReadingBackgroundPainter extends CustomPainter {
  const ReadingBackgroundPainter(this.color, this.image);
  final Color color;
  final ui.Image? image;
  @override
  void paint(Canvas canvas, Size size) =>
      paintReadingBackground(canvas, size, color, image);
  @override
  bool shouldRepaint(ReadingBackgroundPainter old) =>
      old.color != color || old.image != image;
}
