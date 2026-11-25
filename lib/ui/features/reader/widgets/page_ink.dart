import 'dart:typed_data';
import 'dart:ui';

/// 原纸面坐标中的一小块透明笔迹。正文大图在整次翻页中可以继续复用。
class PageInk {
  PageInk(this.picture, this.bounds, this.ratio);
  final Picture picture;
  final Rect bounds;
  final double ratio;
  Image? _image;

  Image get image => _image ??= _rasterize();
  Image _rasterize() {
    final recorder = PictureRecorder();
    Canvas(recorder)
      ..scale(ratio)
      ..drawPicture(picture);
    final scaled = recorder.endRecording();
    try {
      return scaled.toImageSync(
        (bounds.width * ratio).round(),
        (bounds.height * ratio).round(),
      );
    } finally {
      scaled.dispose();
    }
  }

  void paint(Canvas canvas) {
    canvas.save();
    canvas.translate(bounds.left, bounds.top);
    canvas.drawPicture(picture);
    canvas.restore();
  }

  void dispose() {
    _image?.dispose();
    picture.dispose();
  }
}

/// 网格和页图共用纹理坐标。双页裁出半张纸时，左半页在纸背或正面上镜像。
class LeafInk {
  const LeafInk(this.ink, this.bounds, {this.mirror = false});
  final PageInk ink;
  final Rect bounds;
  final bool mirror;

  void paint(Canvas canvas) {
    canvas.save();
    canvas.translate(mirror ? bounds.right : bounds.left, bounds.top);
    if (mirror) canvas.scale(-1, 1);
    canvas.drawPicture(ink.picture);
    canvas.restore();
  }

  ImageShader shader(Size pixels, Size leaf) {
    final image = ink.image;
    final sx = pixels.width / leaf.width, sy = pixels.height / leaf.height;
    return ImageShader(
      image,
      TileMode.decal,
      TileMode.decal,
      Float64List.fromList([
        (mirror ? -1 : 1) * bounds.width * sx / image.width,
        0,
        0,
        0,
        0,
        bounds.height * sy / image.height,
        0,
        0,
        0,
        0,
        1,
        0,
        (mirror ? bounds.right : bounds.left) * sx,
        bounds.top * sy,
        0,
        1,
      ]),
      filterQuality: FilterQuality.low,
    );
  }
}
