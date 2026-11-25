import 'dart:math' as math;
import 'dart:ui';

/// 保留原图尺寸，绘制时用当前元素内容框计算图片的位置。书内一张图可以有多个不同的 fit。
class BookImageFit {
  const BookImageFit._(this.mode, this.intrinsic);
  final String mode;
  final Size intrinsic;

  static BookImageFit? of(String? mode, num? width, num? height) {
    if (mode == null ||
        mode == 'fill' ||
        width == null ||
        height == null ||
        width <= 0 ||
        height <= 0) {
      return null;
    }
    return BookImageFit._(mode, Size(width.toDouble(), height.toDouble()));
  }

  Rect destination(Rect box) {
    final sx = box.width / intrinsic.width, sy = box.height / intrinsic.height;
    final scale = switch (mode) {
      'cover' => math.max(sx, sy),
      'contain' => math.min(sx, sy),
      'scale-down' => math.min(1.0, math.min(sx, sy)),
      'none' => 1.0,
      _ => null,
    };
    return scale == null
        ? box
        : Rect.fromCenter(
            center: box.center,
            width: intrinsic.width * scale,
            height: intrinsic.height * scale,
          );
  }

  List<Object> toJson() => [mode, intrinsic.width, intrinsic.height];

  static BookImageFit? fromJson(Object? raw) => raw is List && raw.length == 3
      ? of(raw[0] as String, raw[1] as num, raw[2] as num)
      : null;
}
