/// 把一个文字片段在章节样式表里的样式，翻成测量器要用的显示属性。
///
/// 2026-10-31 收尾后正文片段只剩 `styleId`，不再带粗体、颜色、下划线、上下标
/// 这些旧字段；测量与绘制必须从这里按 `styleId` 取，否则会退化成纯黑普通文字
/// （真机表现：章题红色消失、脚注 [1] 不上标、引文下划线消失）。
///
/// 旧正文测试夹具仍可能直接在片段上写这些字段；没有 `styleId` 时按旧字段兜底，
/// 保证只依赖正文模型的测试不需要额外建表。
library;

import '../../domain/models/book_document.dart';
import '../styles/computed_style.dart';
import '../styles/style_box_value.dart';
import '../styles/style_table.dart';
import '../styles/style_value.dart';

class ResolvedRunStyle {
  const ResolvedRunStyle({
    this.bold = false,
    this.italic = false,
    this.superscript = false,
    this.subscript = false,
    this.underline = false,
    this.strike = false,
    this.color,
    this.sizeScale = 1,
    this.hasFontSize = false,
  });

  /// 片段没有 `styleId`（旧正文或测试夹具）时，沿用片段自带的旧字段。
  factory ResolvedRunStyle.of(TextRun run, StyleTable? table) {
    final id = run.styleId;
    if (table == null || id == null) {
      return ResolvedRunStyle(
        bold: run.bold,
        italic: run.italic,
        superscript: run.superscript,
        subscript: run.subscript,
        underline: run.underline,
        strike: run.strike,
        color: run.color,
        sizeScale: run.sizeScale,
        hasFontSize: run.sizeScale != 1,
      );
    }
    return ResolvedRunStyle.fromStyle(table[id]);
  }

  factory ResolvedRunStyle.fromStyle(ComputedStyle style) {
    final decoration = style.text.decoration?.lines ?? const {};
    final vertical = style.text.verticalAlign;
    final superscript =
        vertical is VerticalAlignKeyword && vertical.keyword == 'super';
    final subscript =
        vertical is VerticalAlignKeyword && vertical.keyword == 'sub';
    return ResolvedRunStyle(
      bold: style.text.fontWeight?.isBold ?? false,
      italic:
          style.text.fontStyle == FontStyleSpecValue.italic ||
          style.text.fontStyle == FontStyleSpecValue.oblique,
      superscript: superscript,
      subscript: subscript,
      underline: decoration.contains(TextDecorationLine.underline),
      strike: decoration.contains(TextDecorationLine.lineThrough),
      color: style.text.color?.argb,
      sizeScale: switch (style.text.fontSize) {
        RelativeFontSize(:final factor) => factor,
        _ => 1.0,
      },
      hasFontSize: style.text.fontSize is RelativeFontSize,
    );
  }

  final bool bold;
  final bool italic;
  final bool superscript;
  final bool subscript;
  final bool underline;
  final bool strike;

  /// 书里写的 ARGB 颜色；null 表示跟随阅读主题。
  final int? color;

  /// 相对字号（`small`、`0.9em` 等）；1 表示正文字号。
  final double sizeScale;
  final bool hasFontSize;

  bool get isScript => superscript || subscript;

  /// 把解析结果写回一个只用于显示的片段副本。
  ///
  /// 测量结果仍要保留 `styleId`、链接和脚注标记：它们不是样式，是正文结构与交互。
  TextRun applyTo(TextRun run) => TextRun(
    run.text,
    bold: bold,
    italic: italic,
    superscript: superscript,
    subscript: subscript,
    color: color,
    sizeScale: sizeScale,
    underline: underline,
    strike: strike,
    link: run.link,
    footnote: run.footnote,
    styleId: run.styleId,
  );
}
