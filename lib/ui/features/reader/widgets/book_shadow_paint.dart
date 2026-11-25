import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

typedef BookShadowPainter = void Function(Canvas, RRect, List<BoxShadow>);

/// CSS 外阴影只落在盒子外部。透明背景也要挖掉中间。
void paintBookShadows(Canvas canvas, RRect shape, List<BoxShadow> shadows) {
  canvas.save();
  canvas.clipPath(
    Path.combine(
      PathOperation.difference,
      Path()..addRect(shape.outerRect.inflate(1000)),
      Path()..addRRect(shape),
    ),
  );
  for (final shadow in shadows) {
    canvas.drawRRect(
      shape.inflate(shadow.spreadRadius).shift(shadow.offset),
      Paint()
        ..color = shadow.color
        ..maskFilter = shadow.blurRadius > 0
            ? MaskFilter.blur(BlurStyle.normal, shadow.blurRadius / 2)
            : null,
    );
  }
  canvas.restore();
}

/// 直边中段的阴影处处相同。按屏幕密度画一次四角和一小段直边，再铺到真实框边。
class BookShadowCache {
  BookShadowCache(this.pixelRatio);
  final double pixelRatio;
  final _tiles = <(RRect, BoxShadow, double), ui.Image>{};
  int _bytes = 0;
  static const _budget = 4 * 1024 * 1024;

  void paint(Canvas canvas, RRect shape, List<BoxShadow> shadows) {
    final ratio = pixelRatio;
    for (final shadow in shadows) {
      final dx = shadow.offset.dx.abs(), dy = shadow.offset.dy.abs();
      final halo = shadow.spreadRadius.abs() + 2 * shadow.blurRadius;
      // 裁切线位于圆角和模糊取样范围以外，两侧各多留两个物理像素。
      final radiusX = math.max(
        math.max(shape.tlRadiusX, shape.trRadiusX),
        math.max(shape.blRadiusX, shape.brRadiusX),
      );
      final radiusY = math.max(
        math.max(shape.tlRadiusY, shape.trRadiusY),
        math.max(shape.blRadiusY, shape.brRadiusY),
      );
      final insetX = ((radiusX + halo + dx) * ratio).ceil() + 2;
      final insetY = ((radiusY + halo + dy) * ratio).ceil() + 2;
      final padX = ((halo + dx) * ratio).ceil() + 2;
      final padY = ((halo + dy) * ratio).ceil() + 2;
      final width = math.min(shape.width, (2 * insetX + 2) / ratio);
      final height = math.min(shape.height, (2 * insetY + 2) / ratio);
      final w = (width * ratio).ceil() + 2 * padX;
      final h = (height * ratio).ceil() + 2 * padY;
      if (w * h * 4 > _budget || w > 4096 || h > 4096) {
        paintBookShadows(canvas, shape, [shadow]);
        continue;
      }
      final tile = RRect.fromRectAndCorners(
        Rect.fromLTWH(0, 0, width, height),
        topLeft: shape.tlRadius,
        topRight: shape.trRadius,
        bottomLeft: shape.blRadius,
        bottomRight: shape.brRadius,
      );
      final key = (tile, shadow, ratio);
      var image = _tiles.remove(key);
      if (image == null) {
        final recorder = ui.PictureRecorder();
        final target = Canvas(recorder)
          ..translate(padX.toDouble(), padY.toDouble())
          ..scale(ratio);
        paintBookShadows(target, tile, [shadow]);
        final picture = recorder.endRecording();
        image = picture.toImageSync(w, h);
        picture.dispose();
        _bytes += w * h * 4;
      }
      _tiles[key] = image;
      // drawImageNine 的四角以源像素为单位，目标也换成物理像素。
      final center = Rect.fromLTWH(
        (w ~/ 2).toDouble(),
        (h ~/ 2).toDouble(),
        1,
        1,
      );
      final dest = Rect.fromLTWH(
        shape.left * ratio - padX,
        shape.top * ratio - padY,
        w + (shape.width - width) * ratio,
        h + (shape.height - height) * ratio,
      );
      canvas.save();
      canvas.scale(1 / ratio);
      canvas.drawImageNine(
        image,
        center,
        dest,
        Paint()..filterQuality = FilterQuality.low,
      );
      canvas.restore();
      while (_bytes > _budget || _tiles.length > 96) {
        final oldest = _tiles.remove(_tiles.keys.first)!;
        _bytes -= oldest.width * oldest.height * 4;
        oldest.dispose();
      }
    }
  }

  void dispose() {
    for (final tile in _tiles.values) {
      tile.dispose();
    }
    _tiles.clear();
    _bytes = 0;
  }
}
