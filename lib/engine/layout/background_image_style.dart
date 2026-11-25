import '../styles/property_parsers.dart';
import '../styles/style_box_value.dart';
import '../styles/style_value.dart';

/// 已核对为书内资源的背景，长度在绘制时结合实际盒子换算。
class BookBackgroundImage {
  const BookBackgroundImage(this.style, this.fontSize, this.rootFontSize);
  final BackgroundSpec style;
  final double fontSize, rootFontSize;
  String get path => style.imageUrl!;

  /// 只有实际使用纵向可用空间的背景需要等到容器末页。百分比宽度仍可当页确定。
  bool get needsFullHeight {
    final size = (style.size ?? 'auto').trim().toLowerCase();
    final lengths = StyleParser.splitTokens(size);
    final repeat = (style.repeat ?? 'repeat').trim().toLowerCase().split(
      RegExp(r'\s+'),
    );
    final ry = repeat.last;
    final pos = backgroundPosition(style.position ?? '0% 0%').$2;
    return size == 'cover' ||
        size == 'contain' ||
        (lengths.length > 1 && lengths[1].contains('%')) ||
        RegExp(r'v(?:h|min|max)').hasMatch(size) ||
        pos.dependsOnHeight ||
        ry == 'space' ||
        ry == 'round';
  }

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

class BackgroundAxis {
  const BackgroundAxis(this.anchor, [this.length, this.edge = false]);
  final double anchor;
  final Length? length;
  final bool edge;
  bool get dependsOnHeight =>
      anchor != 0 ||
      (length is PercentLength && (length! as PercentLength).value != 0);

  double offset(double span, double image, LengthContext context) {
    final free = span - image;
    if (length == null) return free * anchor;
    if (!edge && length is PercentLength) {
      return free * (length! as PercentLength).value;
    }
    final offset = length!.resolve(context);
    return edge ? free * anchor + (anchor == 1 ? -offset : offset) : offset;
  }
}

(BackgroundAxis, BackgroundAxis) backgroundPosition(String raw) {
  final tokens = raw.toLowerCase().trim().split(RegExp(r'\s+'));
  BackgroundAxis? x, y;
  if (tokens.length <= 2) {
    var a = tokens.first, b = tokens.length == 1 ? 'center' : tokens[1];
    if (a == 'top' || a == 'bottom' || b == 'left' || b == 'right') {
      final swap = a;
      a = b;
      b = swap;
    }
    BackgroundAxis axis(String value) => switch (value) {
      'center' => const BackgroundAxis(.5),
      'right' || 'bottom' => const BackgroundAxis(1),
      'left' || 'top' => const BackgroundAxis(0),
      _ => BackgroundAxis(0, StyleParser.length(value)),
    };
    return (axis(a), axis(b));
  }
  for (var i = 0; i < tokens.length; i++) {
    final token = tokens[i];
    if (token == 'left' ||
        token == 'right' ||
        token == 'top' ||
        token == 'bottom') {
      final length = i + 1 < tokens.length
          ? StyleParser.length(tokens[i + 1])
          : null;
      if (length != null) i++;
      final axis = BackgroundAxis(
        token == 'right' || token == 'bottom' ? 1 : 0,
        length,
        true,
      );
      if (token == 'left' || token == 'right') {
        x = axis;
      } else {
        y = axis;
      }
    } else if (token == 'center') {
      if (x == null) {
        x = const BackgroundAxis(.5);
      } else {
        y = const BackgroundAxis(.5);
      }
    }
  }
  return (x ?? const BackgroundAxis(.5), y ?? const BackgroundAxis(.5));
}
