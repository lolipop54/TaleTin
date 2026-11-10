/// 一个正文块用于排版的样式输入（显示树里“节点的样式”部分）。
///
/// 方案 2 收尾后，正文块只有 `styleId`，样式一律从本章样式表取；这一层负责把
/// 「计算样式」翻成测量器一直用的旧字段形状（对齐字符串、百分之一 em 的整数数组等），
/// 单位换算仍留给排版上下文（像素要字号、容器宽度）。
///
/// 换算函数放在 `LegacyStyleAdapter` 里，和迁移期对照用的 `legacyJson` 共用同一套，
/// 避免两处各写一遍导致数值不一致。
library;

import '../../domain/models/book_document.dart';
import '../styles/computed_style.dart';
import '../styles/legacy_style_adapter.dart';
import '../styles/style_table.dart';
import '../styles/style_value.dart';

class ResolvedBlockStyle {
  const ResolvedBlockStyle({
    this.computed = ComputedStyle.empty,
    this.align,
    this.noIndent = false,
    this.listStyle,
    this.ordered = false,
    this.ordinal,
    this.letterSpacing,
    this.wordSpacing,
    this.rawBox,
    this.rawTextShadow,
    this.rawMargin,
    this.rawImageWidth,
    this.rawImageMaxWidth,
    this.rawLine,
    this.nest = 0,
  });

  /// 从正文块与本章样式表读出排版要用的样式字段。
  ///
  /// 块没有 `styleId`（或没有表）时按默认样式 0 处理：正文本来就没有样式，
  /// 排版层不必再区分「有没有表」这条分支。
  factory ResolvedBlockStyle.of(
    ContentBlock block, {
    StyleTable? table,
    int? nestOverride,
  }) => ResolvedBlockStyle.fromStyle(
    block,
    table?[block.styleId ?? kDefaultStyleId] ?? ComputedStyle.empty,
    nestOverride: nestOverride,
  );

  /// 从一条计算样式读出排版字段；结构字段（列表序号、嵌套、分隔线线型）仍在块上。
  ///
  /// [nestOverride] 给表格单元格用：单元格已经在表格列宽里定位，不能再叠加
  /// 引用／列表的嵌套缩进。
  factory ResolvedBlockStyle.fromStyle(
    ContentBlock block,
    ComputedStyle style, {
    int? nestOverride,
    LengthContext? context,
  }) => ResolvedBlockStyle(
    computed: style,
    align: LegacyStyleAdapter.alignOf(style.block.textAlign),
    noIndent: LegacyStyleAdapter.noIndentOf(style.block.textIndent),
    listStyle: LegacyStyleAdapter.listStyleOf(style.block.listStyle),
    ordered: block.ordered,
    ordinal: block.ordinal,
    letterSpacing: _spacing(style.text.letterSpacing, context),
    wordSpacing: _spacing(style.text.wordSpacing, context),
    rawBox: LegacyStyleAdapter.boxOf(style.box),
    rawTextShadow: LegacyStyleAdapter.shadowOf(style.text.shadow),
    rawMargin: LegacyStyleAdapter.marginOf(style.block.margin),
    rawImageWidth: LegacyStyleAdapter.imageLengthOf(style.size.width),
    rawImageMaxWidth: LegacyStyleAdapter.imageLengthOf(style.size.maxWidth),
    rawLine: block.line,
    nest: nestOverride ?? block.nest,
  );

  static double? _spacing(Length? value, LengthContext? context) {
    if (context == null) return LegacyStyleAdapter.spacingOf(value);
    return value == null || value.isAuto
        ? null
        : value.resolve(context) / context.fontSize;
  }

  /// 块级对齐：`center`／`right`；null 表示左对齐（两端对齐由排版层决定）。
  final ComputedStyle computed;
  final String? align;

  /// 书里明确写了 `text-indent: 0`：这一段不缩进。
  final bool noIndent;

  /// 列表标记类型编码（0 无、1 数字、2 小写字母……见 `BlockStyleInput.listStyle`）。
  final int? listStyle;

  /// 列表序号：`ordered` 为真时用 [ordinal] 画数字/字母标记。
  final bool ordered;
  final int? ordinal;

  /// 字距／词距（相对字号）；null 表示书里没写。
  final double? letterSpacing;
  final double? wordSpacing;

  /// 盒子的原始数组（单位百分之一 em），换算像素由测量器完成。
  final List<int>? rawBox;

  /// 文字阴影 `[x, y, 模糊, 颜色]`（百分之一 em）。
  final List<int>? rawTextShadow;

  /// 四边外边距 `[上, 右, 下, 左]`（百分之一 em）。
  final List<int>? rawMargin;

  /// 图片显式宽度／最大宽度 `[数值, 单位]`（单位 1 百分比、2 em、3 px）。
  final List<int>? rawImageWidth;
  final List<int>? rawImageMaxWidth;

  /// 分隔线线型 `[宽度(百分之一 em), 样式, 颜色]`（结构字段，仍在块上）。
  final List<int>? rawLine;

  /// 引用/列表嵌套层级（结构性的缩进来源）。
  final int nest;

  /// 书里是否要求首行缩进（没写或写了非 0 都要缩）。
  bool get wantsIndent => !noIndent;

  /// 外边距换算成像素：`side` 0 上、2 下；按这一块的实际字号乘。
  double marginPixels(
    int side,
    double fontSize, {
    double? reference,
    double? rootFontSize,
  }) {
    final edges = computed.block.margin;
    final length = side == 0
        ? edges?.top
        : side == 2
        ? edges?.bottom
        : null;
    if (length != null) {
      return length.isAuto
          ? 0
          : length.resolve(
              LengthContext(
                fontSize: fontSize,
                rootFontSize: rootFontSize ?? fontSize,
                reference: reference ?? fontSize,
              ),
            );
    }
    final margin = rawMargin;
    if (margin == null || margin.length < 4) return 0;
    return margin[side] / 100 * fontSize;
  }
}
