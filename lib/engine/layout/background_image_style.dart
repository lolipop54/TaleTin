import '../styles/style_box_value.dart';
import '../styles/style_value.dart';

/// 已核对为书内资源的背景，长度在绘制时结合实际盒子换算。
class BookBackgroundImage {
  const BookBackgroundImage(this.style, this.fontSize, this.rootFontSize);
  final BackgroundSpec style;
  final double fontSize, rootFontSize;
  String get path => style.imageUrl!;
  static BookBackgroundImage? resolve(
    BackgroundSpec? style,
    LengthContext ctx,
  ) => style?.imageUrl?.startsWith('res/') == true
      ? BookBackgroundImage(style!, ctx.fontSize, ctx.rootFontSize)
      : null;
  Map<String, Object?> toJson() => {
    'style': style.toJson(),
    'font': fontSize,
    'root': rootFontSize,
  };
  static BookBackgroundImage? fromJson(Object? value) {
    if (value is! Map) return null;
    final style = BackgroundSpec.fromJson(value['style']);
    return style?.imageUrl?.startsWith('res/') == true
        ? BookBackgroundImage(
            style!,
            (value['font'] as num).toDouble(),
            (value['root'] as num).toDouble(),
          )
        : null;
  }
}
