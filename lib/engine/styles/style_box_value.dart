/// 盒子、装饰、列表、文字装饰等成组样式值。
///
/// 和 [style_value.dart] 一样：只描述「书里写了什么」，不乘成像素、不挑字体。
/// 这些值以后会被块流／行内流／绘制分别消费，但值本身的写法与消费者无关。
library;

import 'style_value.dart';

/// 字体粗细。CSS 用 100～900，100 的倍数。
///
/// 阅读器只在「正文基准字重」这一层生效：书里的 `font-weight: 700` 表示
/// 「比父级更粗」，`normal` 表示回到 400，不能直接覆盖用户设置的正文字重。
/// `bolder`／`lighter` 是相对父级的两档增减，必须先知道父级字重，
/// 所以在值里保留 [mode]，到层叠时再算成具体数字。
class FontWeightSpec {
  const FontWeightSpec(this.value, {this.mode = FontWeightMode.absolute});

  /// 400 是 normal，700 是 bold；相对模式下 value 只记录写的是哪一档。
  final int value;
  final FontWeightMode mode;

  static const FontWeightSpec normal = FontWeightSpec(400);
  static const FontWeightSpec bold = FontWeightSpec(700);

  bool get isBold => mode == FontWeightMode.absolute
      ? value >= 600
      : value > 400;

  bool get isRelative => mode != FontWeightMode.absolute;

  /// 相对父级算出具体字重；绝对模式原样返回。
  FontWeightSpec resolveAgainst(FontWeightSpec parent) => switch (mode) {
    FontWeightMode.absolute => this,
    FontWeightMode.bolder => parent._shift(300),
    FontWeightMode.lighter => parent._shift(-300),
  };

  FontWeightSpec _shift(int delta) => FontWeightSpec((value + delta).clamp(100, 900));

  Object? toJson() => mode == FontWeightMode.absolute
      ? value
      : {'v': value, 'm': mode.name};
  static FontWeightSpec? fromJson(Object? json) {
    if (json is num) return FontWeightSpec(json.toInt());
    if (json is! Map) return null;
    final value = (json['v'] as num?)?.toInt();
    if (value == null) return null;
    final mode = _byName(FontWeightMode.values, json['m']);
    return FontWeightSpec(value, mode: mode ?? FontWeightMode.absolute);
  }

  @override
  String toString() => isRelative ? '${mode.name}($value)' : '$value';
}

enum FontWeightMode { absolute, bolder, lighter }

enum FontStyleSpecValue { normal, italic, oblique }

enum TextAlignSpec {
  /// 只用于 `text-align-last`：跟随 `text-align`（CSS 初始值就是 auto）。
  auto,
  start,
  end,
  left,
  right,
  center,
  justify,
  justifyAll,
}

enum TextTransformSpec {
  none,
  capitalize,
  uppercase,
  lowercase,
}

/// `white-space`。我们只区分「空白怎么处理」和「能不能自动换行」两件事。
enum WhiteSpaceSpec {
  /// 折叠空白、可换行（默认）。
  normal,

  /// 保留空白与换行、不自动换行（代码块以逐行测量实现换行，不靠这个自动换行）。
  pre,

  /// 保留空白与换行，也能自动换行。
  preWrap,

  /// 折叠空白但保留换行。
  preLine,

  /// 折叠空白、不自动换行。
  nowrap,

  /// 保留空白与换行，段尾空格也不悬挂。
  breakSpaces,
}

/// `display`。本次只实现 block／inline／list-item／table 系列的现有行为，
/// `none` 被产品规则挡住（隐藏文字会破坏搜索、听书和进度），其它值先记录。
enum DisplaySpec {
  block,
  inline,
  inlineBlock,
  listItem,
  table,
  inlineTable,
  tableRowGroup,
  tableHeaderGroup,
  tableFooterGroup,
  tableRow,
  tableCell,
  tableCaption,
  tableColumnGroup,
  tableColumn,
  flex,
  inlineFlex,
  grid,
  inlineGrid,
  flowRoot,
  none,
  contents,
}

enum FloatSpec { none, left, right, inlineStart, inlineEnd }

enum ClearSpec { none, left, right, both }

enum PositionSpec { static, relative, absolute, fixed, sticky }

enum BoxSizingSpec { contentBox, borderBox }

/// 边框线型。`none`／`hidden` 表示不画；`hidden` 在 border-collapse 里另有语义，
/// 我们目前只按「不画」处理并记录原值。
enum BorderLineStyle {
  none,
  hidden,
  solid,
  dashed,
  dotted,
  double,
  groove,
  ridge,
  inset,
  outset,
}

class BorderSideSpec {
  const BorderSideSpec({this.width, this.style, this.color});

  final Length? width;
  final BorderLineStyle? style;
  final ColorValue? color;

  bool get isVisible {
    if (style == BorderLineStyle.none || style == BorderLineStyle.hidden) {
      return false;
    }
    // 宽度写了 0 也不画；写的是 em／% 时按当前字号/宽度算，解析后再判断。
    final width = this.width;
    if (width is PxLength) return width.value > 0;
    return true;
  }

  Map<String, Object?> toJson() => {
    if (width != null) 'w': width!.toJson(),
    if (style != null) 's': style!.name,
    if (color != null) 'c': color!.toJson(),
  };

  static BorderSideSpec? fromJson(Object? json) {
    if (json is! Map) return null;
    return BorderSideSpec(
      width: lengthFromJson(json['w']),
      style: _byName(BorderLineStyle.values, json['s']),
      color: ColorValue.fromJson(json['c']),
    );
  }

  @override
  String toString() => [width, style?.name, color].join(' ');
}

/// 边框字段级合并：只覆盖自己写了的部分，没写的保留 [base]。
///
/// `border: 1px solid red` 之后再写 `border-color: blue`，颜色要盖掉、
/// 宽度和线型要留下；所以不能整边替换，必须逐字段合并。
BorderSideSpec mergeBorderSide(BorderSideSpec? top, BorderSideSpec? base) {
  if (top == null) return base ?? const BorderSideSpec();
  if (base == null) return top;
  return BorderSideSpec(
    width: top.width ?? base.width,
    style: top.style ?? base.style,
    color: top.color ?? base.color,
  );
}

/// 四边边框。每边可以单独写，也可以由 `border` 简写一次设置四边。
class BorderSpec {
  const BorderSpec({this.top, this.right, this.bottom, this.left});

  const BorderSpec.all(BorderSideSpec side)
    : top = side,
      right = side,
      bottom = side,
      left = side;

  final BorderSideSpec? top;
  final BorderSideSpec? right;
  final BorderSideSpec? bottom;
  final BorderSideSpec? left;

  bool get isEmpty =>
      top == null && right == null && bottom == null && left == null;

  Map<String, Object?> toJson() => {
    if (top != null) 't': top!.toJson(),
    if (right != null) 'r': right!.toJson(),
    if (bottom != null) 'b': bottom!.toJson(),
    if (left != null) 'l': left!.toJson(),
  };

  static BorderSpec? fromJson(Object? json) {
    if (json is! Map) return null;
    return BorderSpec(
      top: BorderSideSpec.fromJson(json['t']),
      right: BorderSideSpec.fromJson(json['r']),
      bottom: BorderSideSpec.fromJson(json['b']),
      left: BorderSideSpec.fromJson(json['l']),
    );
  }

  /// 逐边、逐字段合并；[base] 是优先级更低的一层。
  BorderSpec mergeOver(BorderSpec base) => BorderSpec(
    top: mergeBorderSide(top, base.top),
    right: mergeBorderSide(right, base.right),
    bottom: mergeBorderSide(bottom, base.bottom),
    left: mergeBorderSide(left, base.left),
  );
}

class CornerRadii {
  const CornerRadii({this.topLeft, this.topRight, this.bottomRight, this.bottomLeft});

  const CornerRadii.all(Length value)
    : topLeft = value,
      topRight = value,
      bottomRight = value,
      bottomLeft = value;

  final Length? topLeft;
  final Length? topRight;
  final Length? bottomRight;
  final Length? bottomLeft;

  bool get isEmpty =>
      topLeft == null && topRight == null && bottomRight == null && bottomLeft == null;

  Map<String, Object?> toJson() => {
    if (topLeft != null) 'tl': topLeft!.toJson(),
    if (topRight != null) 'tr': topRight!.toJson(),
    if (bottomRight != null) 'br': bottomRight!.toJson(),
    if (bottomLeft != null) 'bl': bottomLeft!.toJson(),
  };

  static CornerRadii? fromJson(Object? json) {
    if (json is! Map) return null;
    return CornerRadii(
      topLeft: lengthFromJson(json['tl']),
      topRight: lengthFromJson(json['tr']),
      bottomRight: lengthFromJson(json['br']),
      bottomLeft: lengthFromJson(json['bl']),
    );
  }
}

/// 一层阴影。`spread` 只有 box-shadow 有，text-shadow 恒为 null。
class ShadowValue {
  const ShadowValue({
    required this.offsetX,
    required this.offsetY,
    this.blur,
    this.spread,
    this.color,
    this.inset = false,
  });

  final Length offsetX;
  final Length offsetY;
  final Length? blur;
  final Length? spread;
  final ColorValue? color;

  /// `box-shadow: inset ...`。第一版只记录，按外阴影画。
  final bool inset;

  Map<String, Object?> toJson() => {
    'x': offsetX.toJson(),
    'y': offsetY.toJson(),
    if (blur != null) 'b': blur!.toJson(),
    if (spread != null) 's': spread!.toJson(),
    if (color != null) 'c': color!.toJson(),
    if (inset) 'i': true,
  };

  static ShadowValue? fromJson(Object? json) {
    if (json is! Map) return null;
    final x = lengthFromJson(json['x']);
    final y = lengthFromJson(json['y']);
    if (x == null || y == null) return null;
    return ShadowValue(
      offsetX: x,
      offsetY: y,
      blur: lengthFromJson(json['b']),
      spread: lengthFromJson(json['s']),
      color: ColorValue.fromJson(json['c']),
      inset: json['i'] == true,
    );
  }
}

/// 背景的颜色、本地图片、平铺方式、位置与尺寸。图片在页面准备时解码，
/// 绘制时再根据实际盒子计算百分比与 cover/contain。
class BackgroundSpec {
  const BackgroundSpec({
    this.color,
    this.imageUrl,
    this.imageGradient,
    this.repeat,
    this.position,
    this.size,
    this.clip,
    this.raw,
  });

  final ColorValue? color;

  /// `url(...)` 里的本地资源地址；外网地址在解析层就丢弃。
  final String? imageUrl;

  /// `linear-gradient(...)` 这类还不支持的写法，原样记录便于覆盖报告。
  final String? imageGradient;

  /// `repeat`／`repeat-x`／`no-repeat` 等原值。
  final String? repeat;
  final String? position;
  final String? size;
  final String? clip;

  /// 简写的原始值。尚未消费的写法（多层背景、非默认 `background-attachment`
  /// 等）原样留在这里，只进覆盖报告，不参与绘制。
  final String? raw;

  bool get isEmpty =>
      color == null &&
      imageUrl == null &&
      imageGradient == null &&
      repeat == null &&
      position == null &&
      size == null &&
      clip == null;

  Map<String, Object?> toJson() => {
    if (color != null) 'c': color!.toJson(),
    if (imageUrl != null) 'u': imageUrl,
    if (imageGradient != null) 'g': imageGradient,
    if (repeat != null) 'r': repeat,
    if (position != null) 'p': position,
    if (size != null) 's': size,
    if (clip != null) 'k': clip,
    if (raw != null) 'raw': raw,
  };

  static BackgroundSpec? fromJson(Object? json) {
    if (json is! Map) return null;
    return BackgroundSpec(
      color: ColorValue.fromJson(json['c']),
      imageUrl: json['u'] as String?,
      imageGradient: json['g'] as String?,
      repeat: json['r'] as String?,
      position: json['p'] as String?,
      size: json['s'] as String?,
      clip: json['k'] as String?,
      raw: json['raw'] as String?,
    );
  }
}

/// 列表标记类型。和 `list-style-type` 对应；不认识的值记 null（按书里没写处理）。
enum ListStyleType {
  none,
  disc,
  circle,
  square,
  decimal,
  decimalLeadingZero,
  lowerAlpha,
  upperAlpha,
  lowerGreek,
  lowerLatin,
  upperLatin,
  lowerRoman,
  upperRoman,
}

enum ListStylePosition { inside, outside }

class ListStyleSpec {
  const ListStyleSpec({this.type, this.position, this.imageUrl});

  final ListStyleType? type;
  final ListStylePosition? position;

  /// `list-style-image`；第一版只记录，列表标记仍按类型绘制。
  final String? imageUrl;

  bool get isEmpty => type == null && position == null && imageUrl == null;

  Map<String, Object?> toJson() => {
    if (type != null) 't': type!.name,
    if (position != null) 'p': position!.name,
    if (imageUrl != null) 'i': imageUrl,
  };

  static ListStyleSpec? fromJson(Object? json) {
    if (json is! Map) return null;
    return ListStyleSpec(
      type: _byName(ListStyleType.values, json['t']),
      position: _byName(ListStylePosition.values, json['p']),
      imageUrl: json['i'] as String?,
    );
  }
}

enum TextDecorationLine { underline, overline, lineThrough, blink }

enum TextDecorationLineStyle { solid, double, dotted, dashed, wavy }

/// 文字装饰。`none` 必须是「明确写了 none」，才能取消链接的默认下划线；
/// 没写（null）和写 none 在层叠里是两件事。
class TextDecorationSpec {
  const TextDecorationSpec({
    this.lines = const {},
    this.color,
    this.style,
    this.thickness,
  });

  static const TextDecorationSpec none = TextDecorationSpec();

  final Set<TextDecorationLine> lines;
  final ColorValue? color;
  final TextDecorationLineStyle? style;
  final Length? thickness;

  bool get isNone => lines.isEmpty;

  Map<String, Object?> toJson() => {
    if (lines.isNotEmpty)
      'l': [for (final line in lines) line.name]..sort((a, b) => a.compareTo(b)),
    if (color != null) 'c': color!.toJson(),
    if (style != null) 's': style!.name,
    if (thickness != null) 't': thickness!.toJson(),
  };

  static TextDecorationSpec? fromJson(Object? json) {
    if (json is! Map) return null;
    final lines = <TextDecorationLine>{};
    for (final name in (json['l'] as List? ?? const [])) {
      final line = _byName(TextDecorationLine.values, name);
      if (line != null) lines.add(line);
    }
    return TextDecorationSpec(
      lines: lines,
      color: ColorValue.fromJson(json['c']),
      style: _byName(TextDecorationLineStyle.values, json['s']),
      thickness: lengthFromJson(json['t']),
    );
  }
}

/// `vertical-align`。上下标是我们唯一会真正偏移的情况，其余关键字先记录。
sealed class VerticalAlignSpec {
  const VerticalAlignSpec();
  Object? toJson();
}

final class VerticalAlignKeyword extends VerticalAlignSpec {
  const VerticalAlignKeyword(this.keyword);
  final String keyword;
  @override
  Object? toJson() => keyword;
  @override
  String toString() => keyword;
}

final class VerticalAlignLength extends VerticalAlignSpec {
  const VerticalAlignLength(this.length);
  final Length length;
  @override
  Object? toJson() => {'len': length.toJson()};
  @override
  String toString() => '$length';
}

VerticalAlignSpec? verticalAlignFromJson(Object? json) {
  if (json is String) return VerticalAlignKeyword(json);
  if (json is Map) {
    final length = lengthFromJson(json['len']);
    return length == null ? null : VerticalAlignLength(length);
  }
  return null;
}

/// 按枚举名取值；名字不认识时返回 null（按「这一层没写」处理）。
///
/// 不用 `package:collection` 的 `firstOrNull`，避免样式这层多一个依赖。
T? _byName<T extends Enum>(List<T> values, Object? name) {
  for (final value in values) {
    if (value.name == name) return value;
  }
  return null;
}
