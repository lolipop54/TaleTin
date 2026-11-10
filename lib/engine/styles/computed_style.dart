/// 一个元素最终算出来的作者样式：标签默认 + 作者样式表 + 行内样式。
///
/// 三条规矩：
/// 1. **每个字段都可以是 null**，null 表示「这一层没说过」，交给下一层或阅读器默认值。
///    不能把「没写」当成 `0`／`normal`，否则继承和层叠就没法判断谁覆盖了谁。
/// 2. **保留单位**（em／%／px／auto），不在这里乘成像素。乘成像素发生在排版上下文。
/// 3. 阅读器的基准字号、行高、段距和主题色**不在这个对象里**：它们属于第 1 层和第 5 层，
///    由排版环境在最后一步合并，避免「书里的 1.5em」和「我们的标题增量」互相乘错。
///
/// 字段分组和 CSS 的分组不完全一致，原因写在每个字段旁边：
/// 例如 `width` 同时作用于文本容器和图片，所以单独放进 [SizeStyleSpec]，
/// 而不是在「块」和「替换元素」里各存一份。
library;

import 'style_box_value.dart';
import 'style_value.dart';

/// 文字样式。
class TextStyleSpec {
  const TextStyleSpec({
    this.fontSize,
    this.fontWeight,
    this.fontStyle,
    this.fontFamilies,
    this.legacyFontFamily,
    this.color,
    this.lineHeight,
    this.decoration,
    this.shadow,
    this.letterSpacing,
    this.wordSpacing,
    this.textTransform,
    this.verticalAlign,
    this.whiteSpace,
    this.hyphens,
  });

  /// 相对父级的字号（em／%／rem），或书里写死的 px。见 [FontSizeSpec]。
  final FontSizeSpec? fontSize;
  final FontWeightSpec? fontWeight;
  final FontStyleSpecValue? fontStyle;

  /// 书里声明的字体族和后备顺序，选中「原书字体」时使用。
  final List<String>? fontFamilies;
  // 旧样式表保留原值，以免规范化后合并记录，错位后续 styleId。
  final String? legacyFontFamily;
  final ColorValue? color;
  final LineHeightSpec? lineHeight;
  final TextDecorationSpec? decoration;

  /// `text-shadow`，可以多层，顺序即绘制顺序（后画的在上）。
  final List<ShadowValue>? shadow;
  final Length? letterSpacing;
  final Length? wordSpacing;

  /// 大小写转换。只做 1:1 字符映射（大写／小写／首字母），不改变字符数量。
  final TextTransformSpec? textTransform;
  final VerticalAlignSpec? verticalAlign;
  final WhiteSpaceSpec? whiteSpace;
  final String? hyphens;

  bool get isEmpty =>
      fontSize == null &&
      fontWeight == null &&
      fontStyle == null &&
      fontFamilies == null &&
      legacyFontFamily == null &&
      color == null &&
      lineHeight == null &&
      decoration == null &&
      shadow == null &&
      letterSpacing == null &&
      wordSpacing == null &&
      textTransform == null &&
      verticalAlign == null &&
      whiteSpace == null &&
      hyphens == null;

  /// 覆盖规则：`this` 是更高优先级的一层，只有自己写了的属性才盖掉 [base]。
  TextStyleSpec mergeOver(TextStyleSpec base) => TextStyleSpec(
    fontSize: fontSize ?? base.fontSize,
    fontWeight: fontWeight ?? base.fontWeight,
    fontStyle: fontStyle ?? base.fontStyle,
    fontFamilies: fontFamilies ?? base.fontFamilies,
    legacyFontFamily: legacyFontFamily ?? base.legacyFontFamily,
    color: color ?? base.color,
    lineHeight: lineHeight ?? base.lineHeight,
    decoration: decoration ?? base.decoration,
    shadow: shadow ?? base.shadow,
    letterSpacing: letterSpacing ?? base.letterSpacing,
    wordSpacing: wordSpacing ?? base.wordSpacing,
    textTransform: textTransform ?? base.textTransform,
    verticalAlign: verticalAlign ?? base.verticalAlign,
    whiteSpace: whiteSpace ?? base.whiteSpace,
    hyphens: hyphens ?? base.hyphens,
  );

  static const TextStyleSpec empty = TextStyleSpec();
}

/// 盒子外观：内边距、边框、背景、圆角、阴影。
///
/// 块容器和行内盒子共用这一个分组；行内盒子没有外边距，所以 margin 不在这里。
/// 边框宽度会影响几何（块流要把它算进内容宽度），这不影响放在这里：
/// 「影响不影响几何」是属性注册表上的标记，不是分组的职责。
class BoxStyleSpec {
  const BoxStyleSpec({
    this.padding,
    this.border,
    this.background,
    this.radii,
    this.shadow,
    this.overflow,
  });

  final Edges? padding;
  final BorderSpec? border;
  final BackgroundSpec? background;
  final CornerRadii? radii;

  /// `box-shadow`，可以多层。
  final List<ShadowValue>? shadow;

  /// `overflow`：第一版只记录，不裁剪内容。
  final String? overflow;

  bool get isEmpty =>
      padding == null &&
      border == null &&
      background == null &&
      radii == null &&
      shadow == null &&
      overflow == null;

  BoxStyleSpec mergeOver(BoxStyleSpec base) => BoxStyleSpec(
    padding: padding ?? base.padding,
    border: border ?? base.border,
    background: background ?? base.background,
    radii: radii ?? base.radii,
    shadow: shadow ?? base.shadow,
    overflow: overflow ?? base.overflow,
  );

  static const BoxStyleSpec empty = BoxStyleSpec();
}

/// 块级流里的位置与对齐。
class BlockStyleSpec {
  const BlockStyleSpec({
    this.display,
    this.textAlign,
    this.textAlignLast,
    this.textIndent,
    this.margin,
    this.float,
    this.clear,
    this.position,
    this.inset,
    this.breakBefore,
    this.breakAfter,
    this.breakInside,
    this.listStyle,
  });

  final DisplaySpec? display;

  /// 块级对齐。虽然写在 CSS 的文字属性里，它作用于块容器（包括里面的所有行），
  /// 所以由块流消费，而不是行内流。
  final TextAlignSpec? textAlign;

  /// 最后一行（或被 `<br>` 打断的一行）的对齐；书里常把它写在 `body` 上。
  final TextAlignSpec? textAlignLast;

  /// 首行缩进。百分比按包含块宽度算。
  final Length? textIndent;

  /// 四边外边距。null 表示这一层没写，交由标签默认和阅读器段距决定。
  final Edges? margin;
  final FloatSpec? float;
  final ClearSpec? clear;
  final PositionSpec? position;
  final Edges? inset;

  /// 分页控制（`break-before/after/inside`）；第一版只记录，不改变断页规则。
  final String? breakBefore;
  final String? breakAfter;
  final String? breakInside;
  final ListStyleSpec? listStyle;

  bool get isEmpty =>
      display == null &&
      textAlign == null &&
      textAlignLast == null &&
      textIndent == null &&
      margin == null &&
      float == null &&
      clear == null &&
      position == null &&
      inset == null &&
      breakBefore == null &&
      breakAfter == null &&
      breakInside == null &&
      listStyle == null;

  BlockStyleSpec mergeOver(BlockStyleSpec base) => BlockStyleSpec(
    display: display ?? base.display,
    textAlign: textAlign ?? base.textAlign,
    textAlignLast: textAlignLast ?? base.textAlignLast,
    textIndent: textIndent ?? base.textIndent,
    margin: margin ?? base.margin,
    float: float ?? base.float,
    clear: clear ?? base.clear,
    position: position ?? base.position,
    inset: inset ?? base.inset,
    breakBefore: breakBefore ?? base.breakBefore,
    breakAfter: breakAfter ?? base.breakAfter,
    breakInside: breakInside ?? base.breakInside,
    listStyle: listStyle ?? base.listStyle,
  );

  static const BlockStyleSpec empty = BlockStyleSpec();
}

/// 尺寸：容器和图片共用一份，避免 `width` 在两个分组里各解析一次。
class SizeStyleSpec {
  const SizeStyleSpec({
    this.width,
    this.height,
    this.minWidth,
    this.minHeight,
    this.maxWidth,
    this.maxHeight,
    this.boxSizing,
    this.objectFit,
  });

  final Length? width;
  final Length? height;
  final Length? minWidth;
  final Length? minHeight;
  final Length? maxWidth;
  final Length? maxHeight;

  /// `border-box` 时宽度包含内边距和边框。默认 `content-box`。
  final BoxSizingSpec? boxSizing;

  /// 图片的缩放方式（`object-fit`）；第一版只支持 `contain`／`fill` 的现有行为。
  final String? objectFit;

  bool get isEmpty =>
      width == null &&
      height == null &&
      minWidth == null &&
      minHeight == null &&
      maxWidth == null &&
      maxHeight == null &&
      boxSizing == null &&
      objectFit == null;

  SizeStyleSpec mergeOver(SizeStyleSpec base) => SizeStyleSpec(
    width: width ?? base.width,
    height: height ?? base.height,
    minWidth: minWidth ?? base.minWidth,
    minHeight: minHeight ?? base.minHeight,
    maxWidth: maxWidth ?? base.maxWidth,
    maxHeight: maxHeight ?? base.maxHeight,
    boxSizing: boxSizing ?? base.boxSizing,
    objectFit: objectFit ?? base.objectFit,
  );

  static const SizeStyleSpec empty = SizeStyleSpec();
}

/// 表格自身属性。单元格的边框、对齐复用 [BoxStyleSpec]／[BlockStyleSpec]。
class TableStyleSpec {
  const TableStyleSpec({
    this.borderCollapse,
    this.borderSpacing,
    this.tableLayout,
    this.captionSide,
    this.emptyCells,
  });

  final String? borderCollapse;
  final Length? borderSpacing;
  final String? tableLayout;
  final String? captionSide;
  final String? emptyCells;

  bool get isEmpty =>
      borderCollapse == null &&
      borderSpacing == null &&
      tableLayout == null &&
      captionSide == null &&
      emptyCells == null;

  TableStyleSpec mergeOver(TableStyleSpec base) => TableStyleSpec(
    borderCollapse: borderCollapse ?? base.borderCollapse,
    borderSpacing: borderSpacing ?? base.borderSpacing,
    tableLayout: tableLayout ?? base.tableLayout,
    captionSide: captionSide ?? base.captionSide,
    emptyCells: emptyCells ?? base.emptyCells,
  );

  static const TableStyleSpec empty = TableStyleSpec();
}

/// 一个元素的计算样式（只含作者侧的三层）。
///
/// [extras] 只放「书里出现了、但我们还没进注册表」的属性和原始值，用于覆盖报告；
/// 它不进正文缓存、不参与布局，也不影响样式表的去重结果。
class ComputedStyle {
  const ComputedStyle({
    this.text = TextStyleSpec.empty,
    this.box = BoxStyleSpec.empty,
    this.block = BlockStyleSpec.empty,
    this.size = SizeStyleSpec.empty,
    this.table = TableStyleSpec.empty,
    this.extras = const {},
  });

  final TextStyleSpec text;
  final BoxStyleSpec box;
  final BlockStyleSpec block;
  final SizeStyleSpec size;
  final TableStyleSpec table;
  final Map<String, String> extras;

  static const ComputedStyle empty = ComputedStyle();

  bool get isEmpty =>
      text.isEmpty &&
      box.isEmpty &&
      block.isEmpty &&
      size.isEmpty &&
      table.isEmpty &&
      extras.isEmpty;

  /// 层叠合并：`this` 是更高优先级的层。
  ComputedStyle mergeOver(ComputedStyle base) => ComputedStyle(
    text: text.mergeOver(base.text),
    box: box.mergeOver(base.box),
    block: block.mergeOver(base.block),
    size: size.mergeOver(base.size),
    table: table.mergeOver(base.table),
    extras: {...base.extras, ...extras},
  );
}
