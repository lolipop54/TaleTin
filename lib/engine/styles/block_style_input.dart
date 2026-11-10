/// 建样式表用的「样式输入」：一块的旧显示字段，值类型，不可变。
///
/// 这是**解析/迁移期的中间产物**，不属于正文模型：正文块只存文字和结构，
/// 显示语义统一进章节样式表（`StyleTable`，块上只留 `styleId`）。
/// 需要它的地方只有三处：
/// - 旧正文 JSON 解码（`ChapterStyler.decode` 把旧键读成样式输入再建表）；
/// - 测试夹具（`styledContent(blocks, styles: [...])`）；
/// - 对照工具（`LegacyStyleAdapter.blockStyleOfSpec`）。
/// 字段名与旧 JSON 键一一对应。
library;

class BlockStyleInput {
  const BlockStyleInput({
    this.align,
    this.noIndent = false,
    this.box,
    this.textShadow,
    this.listStyle,
    this.margin,
    this.letterSpacing,
    this.wordSpacing,
    this.imageWidth,
    this.imageMaxWidth,
  });

  /// 为空（全是 null/false）时返回 null，避免每块都挂一个空对象。
  static BlockStyleInput? of({
    String? align,
    bool noIndent = false,
    List<int>? box,
    List<int>? textShadow,
    int? listStyle,
    List<int>? margin,
    double? letterSpacing,
    double? wordSpacing,
    List<int>? imageWidth,
    List<int>? imageMaxWidth,
  }) {
    if (align == null &&
        !noIndent &&
        box == null &&
        textShadow == null &&
        listStyle == null &&
        margin == null &&
        letterSpacing == null &&
        wordSpacing == null &&
        imageWidth == null &&
        imageMaxWidth == null) {
      return null;
    }
    return BlockStyleInput(
      align: align,
      noIndent: noIndent,
      box: box,
      textShadow: textShadow,
      listStyle: listStyle,
      margin: margin,
      letterSpacing: letterSpacing,
      wordSpacing: wordSpacing,
      imageWidth: imageWidth,
      imageMaxWidth: imageMaxWidth,
    );
  }

  /// 从旧 JSON 键解出（`align`/`noIndent`/`box`/`tsh`/`list`/`mg`/`lsp`/`wsp`/`iw`/`imw`）。
  static BlockStyleInput? fromJson(Map<String, Object?> json) {
    List<int>? ints(Object? raw) =>
        raw is List ? [for (final v in raw) (v as num).toInt()] : null;
    return of(
      align: json['align'] as String?,
      noIndent: json['noIndent'] == true,
      box: ints(json['box']),
      textShadow: ints(json['tsh']),
      listStyle: (json['list'] as num?)?.toInt(),
      margin: ints(json['mg']),
      letterSpacing: (json['lsp'] as num?)?.toDouble(),
      wordSpacing: (json['wsp'] as num?)?.toDouble(),
      imageWidth: ints(json['iw']),
      imageMaxWidth: ints(json['imw']),
    );
  }

  /// 块级对齐：`center`／`right`；null 表示按正文默认（左对齐、两端对齐）。
  final String? align;

  /// 明确取消首行缩进（原书写了 `text-indent:0` 的段落、代码块、图注等）。
  final bool noIndent;

  /// 书内样式表给的盒子（背景、边框、圆角、阴影、内边距）。
  ///
  /// 顺序：[背景色, 上边框宽, 右边框宽, 下边框宽, 左边框宽, 边框色,
  /// 左上圆角, 右上圆角, 右下圆角, 左下圆角, 阴影X, 阴影Y, 阴影模糊,
  /// 阴影颜色, 上内边距, 右内边距, 下内边距, 左内边距,
  /// 上边框线型, 右边框线型, 下边框线型, 左边框线型]。
  /// 宽度、圆角、内边距的单位是百分之一 em。
  final List<int>? box;

  /// 书内指定的文字阴影 `[x, y, 模糊, 颜色]`（百分之一 em）。
  final List<int>? textShadow;

  /// 列表标记样式：0 无、1 数字、2 小写字母、3 大写字母、4 小写罗马数字、
  /// 5 大写罗马数字、6 圆点、7 空心圆、8 方块；null 用默认。
  final int? listStyle;

  /// 四边外边距，顺序上、右、下、左，单位百分之一 em。
  final List<int>? margin;

  /// 书里写的字距／词距（相对字号：0.05 表示 0.05em）；null 表示没写。
  final double? letterSpacing;
  final double? wordSpacing;

  /// 图片的显式宽度与最大宽度，格式 `[数值, 单位]`，数值是单位的 1/100。
  /// 单位：1 百分比、2 em、3 px。
  final List<int>? imageWidth;
  final List<int>? imageMaxWidth;
}
