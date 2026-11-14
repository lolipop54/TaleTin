part of 'block_measure.dart';

extension _InlineImageMeasurement on BlockMeasurer {
  /// 只指定一个边时，按源图比例推算另一边；百分比高度缺少确定的包含块高度。
  Size _inlineImageSize(
    InlineImage image,
    double maxWidth, {
    TextStyle? fallbackStyle,
  }) {
    final rawWidth = (image.width ?? 0).toDouble();
    final rawHeight = (image.height ?? 0).toDouble();
    final em = options.textScaler.scale(
      fallbackStyle?.fontSize ?? options.settings.fontSize.toDouble(),
    );
    // 尺寸嗅探失败时按一个字大小兜底，至少能看见占位
    var width = rawWidth > 0 ? rawWidth : em;
    var height = rawHeight > 0 ? rawHeight : width;
    final computed = image.styleId == null ? null : styleTable?[image.styleId!];
    final context = computed == null
        ? null
        : _lengthContext(computed, maxWidth);
    double? sizeOf(Length? value) =>
        value == null || value.isAuto ? null : value.resolve(context!);
    final explicit = computed == null
        ? _imageLength(image.imageWidth, maxWidth)
        : sizeOf(computed.size.width);
    final declaredHeight = computed?.size.height;
    final explicitHeight = declaredHeight is PercentLength
        ? null
        : sizeOf(declaredHeight);
    if (explicit != null && explicit > 0) {
      height *= explicit / width;
      width = explicit;
    }
    if (explicitHeight != null && explicitHeight > 0) {
      if (explicit == null || explicit <= 0) width *= explicitHeight / height;
      height = explicitHeight;
    } else if ((explicit == null || explicit <= 0) && image.noteLink != null) {
      // 无尺寸的脚注图标以一字高显示，源文件的像素仅用于计算比例。
      width *= em / height;
      height = em;
    }
    final cap = computed == null
        ? _imageLength(image.imageMaxWidth, maxWidth)
        : sizeOf(computed.size.maxWidth);
    if (cap != null && cap > 0 && width > cap) {
      final ratio = cap / width;
      width = cap;
      height *= ratio;
    }
    var scale = math.min(1.0, maxWidth / width);
    if (height * scale > options.contentHeight) {
      scale = math.min(scale, options.contentHeight / height);
    }
    return Size(width * scale, height * scale);
  }
}
