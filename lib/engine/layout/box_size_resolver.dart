import 'dart:math' as math;
import 'dart:ui';

import '../styles/computed_style.dart';
import '../styles/style_box_value.dart';
import '../styles/style_value.dart';
import 'measured_block.dart';

/// 先按包含块换算书里的尺寸，再把边框盒尺寸统一转为内容盒尺寸。
/// 分页空间与阅读器限宽由调用方处理，不能成为百分比的计算基准。
class BoxSizeResolver {
  BoxSizeResolver(
    LengthContext context,
    SizeStyleSpec style,
    BlockBox? box, {
    double? parentHeight,
  }) : width = widthOf(context, style, box),
       height = heightOf(context, style, box, parentHeight: parentHeight);

  final BoxAxisSize width;
  final BoxAxisSize height;

  static BoxAxisSize widthOf(
    LengthContext context,
    SizeStyleSpec style,
    BlockBox? box, {
    double? horizontalEdges,
  }) => _axis(
    context,
    context.reference,
    style.width,
    style.minWidth,
    style.maxWidth,
    style.boxSizing == BoxSizingSpec.borderBox
        ? horizontalEdges ?? ((box?.insetLeft ?? 0) + (box?.insetRight ?? 0))
        : 0,
  );

  static BoxAxisSize heightOf(
    LengthContext context,
    SizeStyleSpec style,
    BlockBox? box, {
    double? parentHeight,
    double? verticalEdges,
  }) => _axis(
    context,
    parentHeight,
    style.height,
    style.minHeight,
    style.maxHeight,
    style.boxSizing == BoxSizingSpec.borderBox
        ? verticalEdges ?? ((box?.insetTop ?? 0) + (box?.insetBottom ?? 0))
        : 0,
  );

  static BoxAxisSize _axis(
    LengthContext context,
    double? reference,
    Length? preferred,
    Length? minimum,
    Length? maximum,
    double edges,
  ) {
    double? content(Length? value) {
      if (value == null || value.isAuto) return null;
      final px = switch (value) {
        PercentLength(:final value) =>
          reference == null ? null : reference * value,
        _ => value.resolve(context),
      };
      return px == null ? null : math.max(0.0, px - edges);
    }

    return BoxAxisSize(content(preferred), content(minimum), content(maximum));
  }

  Size image(Size intrinsic) {
    final explicitWidth = width.definite;
    final explicitHeight = height.definite;
    final ratio = intrinsic.width / intrinsic.height;
    if (explicitWidth != null || explicitHeight != null) {
      return Size(
        explicitWidth ?? width.constrain(explicitHeight! * ratio),
        explicitHeight ?? height.constrain(explicitWidth! / ratio),
      );
    }

    // 两轴都是 auto 时，尽量在同时满足 min/max 的前提下保留源图比例。
    final minScale = math.max(
      width.lower / intrinsic.width,
      height.lower / intrinsic.height,
    );
    final maxScale = math.min(
      width.upper / intrinsic.width,
      height.upper / intrinsic.height,
    );
    final scale = math.min(math.max(1.0, minScale), maxScale);
    return Size(
      width.constrain(intrinsic.width * scale),
      height.constrain(intrinsic.height * scale),
    );
  }
}

class BoxAxisSize {
  const BoxAxisSize(this.preferred, this.minimum, this.maximum);

  final double? preferred, minimum, maximum;

  double get lower => minimum ?? 0;
  double get upper => math.max(lower, maximum ?? double.infinity);
  double? get definite => preferred == null ? null : constrain(preferred!);

  double constrain(double value) => value.clamp(lower, upper);

  double use(double automatic) => definite ?? constrain(automatic);
}
