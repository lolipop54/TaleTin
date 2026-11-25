import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import '../../../../engine/layout/book_image_fit.dart';
import '../../../../engine/layout/background_image_style.dart';
import '../../../../engine/parsers/epub/image_sniff.dart';

/// 用资源的原始宽高安排卷首页。读位图描述或 SVG 根标签就够了，不解码整幅像素。
Future<double?> paperImageAspect(File file) async {
  try {
    if (file.path.toLowerCase().endsWith('.svg')) {
      final stream = await file.open();
      try {
        final size = sniffSvgSize(await stream.read(4096));
        return size == null ? null : size.width / size.height;
      } finally {
        await stream.close();
      }
    }
    final buffer = await ui.ImmutableBuffer.fromFilePath(file.path);
    try {
      final image = await ui.ImageDescriptor.encoded(buffer);
      try {
        return image.width / image.height;
      } finally {
        image.dispose();
      }
    } finally {
      buffer.dispose();
    }
  } on Exception {
    // 资源缺失或损坏时仍能阅读前景文字，加载器会记录具体的图片错误。
    return null;
  }
}

/// 正文固定框按最终绘制面积解码。同一资源出现多次时，两轴都要满足最大的用法。
class BookRasterSizes {
  final _sizes = <String, Size>{};

  void include(String path, Size box, BookImageFit? fit) {
    final size = fit?.destination(Offset.zero & box).size ?? box;
    if (size.isEmpty) return;
    _sizes.update(
      path,
      (previous) => largest(previous, size),
      ifAbsent: () => size,
    );
  }

  Size? physical(String path, double ratio) {
    final size = _sizes[path];
    if (size == null) return null;
    return Size(
      (size.width * ratio).ceilToDouble(),
      (size.height * ratio).ceilToDouble(),
    );
  }

  ({Size? pixels, bool cover}) decodeSize(
    String path, {
    required double ratio,
    required Size paper,
    required BookBackgroundImage? root,
    required bool blockBackground,
  }) {
    final drawn = physical(path, ratio);
    final chapterPaper = root?.path == path;
    final paperFit = root?.style.size;
    if (chapterPaper &&
        (paperFit == 'cover' || paperFit == '100% 100%') &&
        !blockBackground &&
        drawn == null) {
      // 固定整页背景有时会按纸面宽高分别拉伸。沿原图比例保留两轴足够的像素，
      // 它与相邻章的 cover 能共用一份解码；最终的拉伸或裁切仍由 CSS 绘制决定。
      return (pixels: paper * ratio, cover: true);
    }
    return (
      pixels: chapterPaper || blockBackground ? null : drawn,
      cover: false,
    );
  }

  static Size largest(Size a, Size b) =>
      Size(math.max(a.width, b.width), math.max(a.height, b.height));
}

/// 两轴对应画布实际采样的像素。ResizeImage 默认禁止放大原图。
/// 原图查看器和依赖固有尺寸的 CSS 背景仍用 FileImage。
ImageProvider bookRasterProvider(
  File file,
  Size? physical, {
  bool cover = false,
}) {
  final source = FileImage(file);
  if (physical == null) return source;
  if (cover) return _CoverFileImage(file, physical);
  return ResizeImage(
    source,
    width: physical.width.toInt(),
    height: physical.height.toInt(),
  );
}

/// 解码器已经知道原图尺寸。按 cover 取两轴所需的较大倍率，保留比例和裁切位置。
class _CoverFileImage extends FileImage {
  const _CoverFileImage(super.file, this.pixels);
  final Size pixels;

  @override
  ImageStreamCompleter loadImage(FileImage key, ImageDecoderCallback decode) =>
      super.loadImage(
        key,
        (buffer, {getTargetSize}) => decode(
          buffer,
          getTargetSize: (w, h) {
            final scale = math.min(
              1.0,
              math.max(pixels.width / w, pixels.height / h),
            );
            return ui.TargetImageSize(
              width: (w * scale).ceil(),
              height: (h * scale).ceil(),
            );
          },
        ),
      );

  @override
  bool operator ==(Object other) =>
      other is _CoverFileImage &&
      other.file.path == file.path &&
      other.pixels == pixels;
  @override
  int get hashCode => Object.hash(runtimeType, file.path, pixels);
}
