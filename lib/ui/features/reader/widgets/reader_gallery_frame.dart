import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// 当前图解码好后再交接；只保留当前图与正在准备的下一张图。
class ReaderGalleryFrame {
  const ReaderGalleryFrame(
    this.widget,
    this.dispose, {
    required this.imageSize,
  });
  final Widget widget;
  final VoidCallback dispose;
  final Size imageSize;

  static Future<ReaderGalleryFrame> load(
    String path,
    BuildContext context,
  ) async {
    if (path.toLowerCase().endsWith('.svg')) {
      final info = await vg.loadPicture(SvgFileLoader(File(path)), context);
      return ReaderGalleryFrame(
        FittedBox(
          fit: BoxFit.contain,
          child: SizedBox.fromSize(
            size: info.size,
            child: CustomPaint(painter: _GallerySvg(info)),
          ),
        ),
        info.picture.dispose,
        imageSize: info.size,
      );
    }
    final width =
        (MediaQuery.sizeOf(context).width *
                MediaQuery.devicePixelRatioOf(context))
            .round();
    final codec = await ui.instantiateImageCodec(
      await File(path).readAsBytes(),
      targetWidth: width,
      allowUpscaling: false,
    );
    try {
      final frame = await codec.getNextFrame();
      return ReaderGalleryFrame(
        RawImage(image: frame.image, fit: BoxFit.contain),
        frame.image.dispose,
        imageSize: Size(
          frame.image.width.toDouble(),
          frame.image.height.toDouble(),
        ),
      );
    } finally {
      codec.dispose();
    }
  }
}

class _GallerySvg extends CustomPainter {
  const _GallerySvg(this.info);
  final PictureInfo info;
  @override
  void paint(Canvas canvas, Size size) => canvas.drawPicture(info.picture);
  @override
  bool shouldRepaint(_GallerySvg old) => old.info != info;
}
