/// 样式值：把阅读器设置、标签默认、作者 CSS 的写法，保存成**带有原始单位**的值。
///
/// 为什么要保留单位：书里写 `margin-top: 1em`，意思是「相对这个元素的字号」。
/// 如果解析时就乘成像素，用户一改字号或纸面宽度，这个值就错了；书里写 `50%`，
/// 意思是「相对包含块宽度」，换个手机宽度也不一样。所以这里只负责「写法 → 值」，
/// 真正乘成像素发生在排版上下文里（[LengthContext]）。
///
/// 这一层不依赖 Flutter，也不认识 Widget：它只描述 CSS 的数学关系。
library;

import 'dart:convert';

/// 值对象按「类型 + 序列化结果」比较。
///
/// 为什么不逐个字段手写 `==`：这些类型以后都会进缓存、参与样式表去重，
/// 统一用 `toJson()` 比较，既保证「能序列化成一样的东西就是同一个值」，
/// 也避免以后加字段时忘了改比较逻辑。
mixin _ValueEquality {
  Object? toJson();

  @override
  bool operator ==(Object other) =>
      other.runtimeType == runtimeType &&
      jsonEncode(other is _ValueEquality ? other.toJson() : other) ==
          jsonEncode(toJson());

  @override
  int get hashCode => Object.hash(runtimeType, jsonEncode(toJson()));
}

/// 把长度、百分比乘成像素时需要的参照值。
///
/// 同一个 `1em` 在不同位置结果不同，所以每次解析都要带一份当前上下文：
/// - [fontSize]：当前元素最终计算出的字号（已经乘过用户字号基准）；
/// - [rootFontSize]：`rem` 的根字号。按产品规则固定等于阅读器正文字号，
///   不跟随书里的 `html { font-size }`，否则书里写 62.5% 会把整本书缩成一半；
/// - [reference]：百分比的参照宽度。CSS 里 margin／padding／width／text-indent
///   的百分比都按**包含块的内容宽度**算，纵向 margin 也一样，所以只留一个；
/// - [viewportWidth]／[viewportHeight]：以后支持 `vw`／`vh` 用。
class LengthContext {
  const LengthContext({
    required this.fontSize,
    required this.rootFontSize,
    required this.reference,
    this.viewportWidth = 0,
    this.viewportHeight = 0,
  });

  final double fontSize;
  final double rootFontSize;
  final double reference;
  final double viewportWidth;
  final double viewportHeight;

  LengthContext copyWith({
    double? fontSize,
    double? rootFontSize,
    double? reference,
    double? viewportWidth,
    double? viewportHeight,
  }) => LengthContext(
    fontSize: fontSize ?? this.fontSize,
    rootFontSize: rootFontSize ?? this.rootFontSize,
    reference: reference ?? this.reference,
    viewportWidth: viewportWidth ?? this.viewportWidth,
    viewportHeight: viewportHeight ?? this.viewportHeight,
  );
}

/// CSS 长度。解析阶段只区分单位，不乘成像素。
sealed class Length with _ValueEquality {
  const Length();

  /// `auto`：宽度是否填满、左右外边距是否居中，由块流按 CSS 2.2 10.3.3 决定。
  bool get isAuto => false;

  /// 这个长度是否依赖参照宽度或字号；影响「换字号/换宽度后要不要重排」的判断。
  bool get isPercent => false;

  double resolve(LengthContext context);

  /// 统一用「带单位的写法」序列化，便于缓存比对和测试断言。
  @override
  Object? toJson();
}

final class EmLength extends Length {
  const EmLength(this.value);
  final double value;
  @override
  bool get isPercent => true;
  @override
  double resolve(LengthContext context) => value * context.fontSize;
  @override
  Object? toJson() => {'u': 'em', 'v': value};
  @override
  String toString() => '${_num(value)}em';
}

final class RemLength extends Length {
  const RemLength(this.value);
  final double value;
  @override
  bool get isPercent => true;
  @override
  double resolve(LengthContext context) => value * context.rootFontSize;
  @override
  Object? toJson() => {'u': 'rem', 'v': value};
  @override
  String toString() => '${_num(value)}rem';
}

/// 百分比。[value] 是比例：`50%` 存 0.5。
final class PercentLength extends Length {
  const PercentLength(this.value);
  final double value;
  @override
  bool get isPercent => true;
  @override
  double resolve(LengthContext context) => value * context.reference;
  @override
  Object? toJson() => {'u': '%', 'v': value};
  @override
  String toString() => '${_num(value * 100)}%';
}

/// 逻辑像素。书里写 `px` 时就是这个；它不随用户字号变化。
final class PxLength extends Length {
  const PxLength(this.value);
  final double value;
  @override
  double resolve(LengthContext context) => value;
  @override
  Object? toJson() => {'u': 'px', 'v': value};
  @override
  String toString() => '${_num(value)}px';
}

/// 磅。1pt = 4/3 CSS px（CSS 规范固定换算，不含设备像素密度）。
final class PtLength extends Length {
  const PtLength(this.value);
  final double value;
  @override
  double resolve(LengthContext context) => value * 4 / 3;
  @override
  Object? toJson() => {'u': 'pt', 'v': value};
  @override
  String toString() => '${_num(value)}pt';
}

/// `auto`。只有块流的水平方向会用它做实际计算；其它地方调用 [resolve] 是编程错误。
final class AutoLength extends Length {
  const AutoLength();
  @override
  bool get isAuto => true;
  @override
  double resolve(LengthContext context) => throw StateError(
    'auto 长度必须先由块流按 CSS 2.2 10.3.3 分配，不能直接解析成像素',
  );
  @override
  Object? toJson() => 'auto';
  @override
  String toString() => 'auto';
}

Length? lengthFromJson(Object? json) {
  if (json == null) return null;
  if (json == 'auto') return const AutoLength();
  if (json is num) return PxLength(json.toDouble());
  if (json is! Map) return null;
  final value = (json['v'] as num?)?.toDouble();
  if (value == null) return null;
  return switch (json['u']) {
    'em' => EmLength(value),
    'rem' => RemLength(value),
    '%' => PercentLength(value),
    'px' => PxLength(value),
    'pt' => PtLength(value),
    _ => null,
  };
}

/// 四边长度，用于 margin／padding／border-width。
class Edges with _ValueEquality {
  const Edges({this.top, this.right, this.bottom, this.left});

  const Edges.all(Length value)
    : top = value,
      right = value,
      bottom = value,
      left = value;

  static const Edges zero = Edges(
    top: PxLength(0),
    right: PxLength(0),
    bottom: PxLength(0),
    left: PxLength(0),
  );

  final Length? top;
  final Length? right;
  final Length? bottom;
  final Length? left;

  bool get isEmpty =>
      top == null && right == null && bottom == null && left == null;

  /// 是否写了 `auto`；块流要靠它判断「宽度非 auto 且左右都 auto 时居中」。
  bool get hasAuto =>
      (top?.isAuto ?? false) ||
      (right?.isAuto ?? false) ||
      (bottom?.isAuto ?? false) ||
      (left?.isAuto ?? false);

  /// 每边解析成像素；没写的边为 null（表示「这一层没说」，交给下一层）。
  ({double? top, double? right, double? bottom, double? left}) resolve(
    LengthContext context,
  ) => (
    top: _resolve(top, context),
    right: _resolve(right, context),
    bottom: _resolve(bottom, context),
    left: _resolve(left, context),
  );

  static double? _resolve(Length? length, LengthContext context) =>
      length == null || length.isAuto ? null : length.resolve(context);

  @override
  Map<String, Object?> toJson() => {
    if (top != null) 't': top!.toJson(),
    if (right != null) 'r': right!.toJson(),
    if (bottom != null) 'b': bottom!.toJson(),
    if (left != null) 'l': left!.toJson(),
  };

  static Edges? fromJson(Object? json) {
    if (json is! Map) return null;
    return Edges(
      top: lengthFromJson(json['t']),
      right: lengthFromJson(json['r']),
      bottom: lengthFromJson(json['b']),
      left: lengthFromJson(json['l']),
    );
  }

  @override
  String toString() => [top, right, bottom, left].join(' ');
}

/// 颜色。保留原始写法（[source]）只为调试和覆盖报告，不参与布局。
class ColorValue with _ValueEquality {
  const ColorValue(this.argb, {this.source, this.isCurrentColor = false});

  /// `currentColor`：取当前元素的 `color`。它不是某个具体颜色，
  /// 所以不能在这里就折成数字，必须留给层叠阶段解析。
  static const ColorValue current = ColorValue(0, isCurrentColor: true);

  /// ARGB 整数，和 Flutter 的 `Color.value` 口径一致。
  final int argb;
  final String? source;
  final bool isCurrentColor;

  int get alpha => (argb >> 24) & 0xFF;
  int get red => (argb >> 16) & 0xFF;
  int get green => (argb >> 8) & 0xFF;
  int get blue => argb & 0xFF;

  bool get isOpaque => alpha == 0xFF;

  @override
  Object? toJson() => isCurrentColor ? 'currentColor' : argb;

  static ColorValue? fromJson(Object? json) {
    if (json == 'currentColor') return current;
    return json is num ? ColorValue(json.toInt()) : null;
  }

  @override
  String toString() => isCurrentColor
      ? 'currentColor'
      : source ?? '#${argb.toRadixString(16).padLeft(8, '0')}';
}

/// 字号写法。
///
/// 按《设计文档》与产品规则：`rem` 的根字号固定是阅读器正文字号；
/// 绝对字号（px／pt）会被记录，是否采用由阅读器覆盖层决定——当前策略是
/// 正文字号永远由用户设置决定，只有书里写的相对倍数才参与层级。
sealed class FontSizeSpec with _ValueEquality {
  const FontSizeSpec();

  /// 解析成像素；相对值需要父级字号，rem 需要根字号。
  double resolve({required double parentFontSize, required double rootFontSize});

  /// 是否相对父级/根变化。绝对字号换字号时不变，测量缓存可以复用。
  bool get isRelative => true;

  @override
  Object? toJson();
}

/// `em`／`%`／关键字：相对父元素字号。
final class RelativeFontSize extends FontSizeSpec {
  const RelativeFontSize(this.factor);
  final double factor;
  @override
  double resolve({
    required double parentFontSize,
    required double rootFontSize,
  }) => parentFontSize * factor;
  @override
  Object? toJson() => {'u': 'em', 'v': factor};
  @override
  String toString() => '${_num(factor)}em';
}

/// `rem`：相对根字号（阅读器正文字号）。
final class RemFontSize extends FontSizeSpec {
  const RemFontSize(this.factor);
  final double factor;
  @override
  double resolve({
    required double parentFontSize,
    required double rootFontSize,
  }) => rootFontSize * factor;
  @override
  Object? toJson() => {'u': 'rem', 'v': factor};
  @override
  String toString() => '${_num(factor)}rem';
}

/// 绝对字号（px／pt）。记录但不改变用户字号基准。
final class AbsoluteFontSize extends FontSizeSpec {
  const AbsoluteFontSize(this.px);
  final double px;
  @override
  bool get isRelative => false;
  @override
  double resolve({
    required double parentFontSize,
    required double rootFontSize,
  }) => px;
  @override
  Object? toJson() => {'u': 'px', 'v': px};
  @override
  String toString() => '${_num(px)}px';
}

FontSizeSpec? fontSizeFromJson(Object? json) {
  if (json is! Map) return null;
  final value = (json['v'] as num?)?.toDouble();
  if (value == null) return null;
  return switch (json['u']) {
    'em' => RelativeFontSize(value),
    'rem' => RemFontSize(value),
    'px' => AbsoluteFontSize(value),
    _ => null,
  };
}

/// 行高写法。
sealed class LineHeightSpec with _ValueEquality {
  const LineHeightSpec();

  /// 解析成像素；`normal` 返回 null，由排版层按字体度量决定。
  double? resolvePx({required double fontSize, required double rootFontSize});

  /// 是否跟着字号变化；只影响「换字号要不要重新测量」。
  bool get isRelative => true;

  @override
  Object? toJson();
}

final class NormalLineHeight extends LineHeightSpec {
  const NormalLineHeight();
  @override
  double? resolvePx({required double fontSize, required double rootFontSize}) =>
      null;
  @override
  Object? toJson() => 'normal';
  @override
  String toString() => 'normal';
}

/// 无单位数字：行高 = 数字 × 元素字号。它会随元素字号变化，必须按数字保存。
final class FactorLineHeight extends LineHeightSpec {
  const FactorLineHeight(this.factor);
  final double factor;
  @override
  double resolvePx({required double fontSize, required double rootFontSize}) =>
      factor * fontSize;
  @override
  Object? toJson() => factor;
  @override
  String toString() => _num(factor);
}

/// 百分比行高：相对元素自身字号。
final class PercentLineHeight extends LineHeightSpec {
  const PercentLineHeight(this.ratio);
  final double ratio;
  @override
  double resolvePx({required double fontSize, required double rootFontSize}) =>
      ratio * fontSize;
  @override
  Object? toJson() => {'u': '%', 'v': ratio};
  @override
  String toString() => '${_num(ratio * 100)}%';
}

/// 长度行高（em／rem／px）。相对字号解析成像素后就是固定行高。
final class LengthLineHeight extends LineHeightSpec {
  const LengthLineHeight(this.length);
  final Length length;
  @override
  bool get isRelative => length.isPercent;
  @override
  double resolvePx({required double fontSize, required double rootFontSize}) =>
      length.resolve(
        LengthContext(
          fontSize: fontSize,
          rootFontSize: rootFontSize,
          // 行高里的百分比按元素自身字号算，不按包含块宽度。
          reference: fontSize,
        ),
      );
  @override
  Object? toJson() => {'u': 'len', 'v': length.toJson()};
  @override
  String toString() => 'line-height($length)';
}

LineHeightSpec? lineHeightFromJson(Object? json) {
  if (json == null) return null;
  if (json == 'normal') return const NormalLineHeight();
  if (json is num) return FactorLineHeight(json.toDouble());
  if (json is! Map) return null;
  if (json['u'] == '%') {
    final ratio = (json['v'] as num?)?.toDouble();
    return ratio == null ? null : PercentLineHeight(ratio);
  }
  if (json['u'] == 'len') {
    final length = lengthFromJson(json['v']);
    return length == null ? null : LengthLineHeight(length);
  }
  return null;
}

/// 数字写法统一：整数不带小数点，其余去掉尾部 0，避免 `1.0em` 与 `1em` 被当成两个值。
String _num(double value) {
  if (value == value.roundToDouble() && value.abs() < 1e9) {
    return value.toInt().toString();
  }
  return value
      .toStringAsFixed(4)
      .replaceFirst(RegExp(r'0+$'), '')
      .replaceFirst(RegExp(r'\.$'), '');
}
