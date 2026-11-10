/// 把「样式输入」（旧显示字段）翻译成计算样式，并登记成样式表。
///
/// 这是批次 C 起一直沿用的**建表桥**：
/// - 旧正文 JSON（块上带显示字段）解码时，把字段读成 [BlockStyleInput] 再翻译成
///   计算样式，登记成一张样式表（`ChapterStyler.attach`）；
/// - 测试夹具用同一入口给合成正文建表；
/// - 反向的 `legacyJson` 把样式表还原成旧字段形状，供迁移期逐字段对照。
///
/// 只翻译**书里带来的**字段：对齐、缩进、盒子、阴影、列表标记、片段的粗体/颜色等。
/// 标题字号、图注字号、代码行高这类**引擎默认值**留在 `layout_options.dart`，
/// 不进样式表；否则等于把引擎默认当成作者样式，反而会盖掉书里的相对倍数。
library;

import '../../domain/models/book_document.dart';
import 'block_style_input.dart';
import 'computed_style.dart';
import 'style_box_value.dart';
import 'style_table.dart';
import 'style_value.dart';

/// 一章的样式 ID 对照：块按顺序一个 ID，片段按块内顺序一串 ID。
class LegacyStyleIds {
  const LegacyStyleIds({
    required this.table,
    required this.blockIds,
    required this.runIds,
  });

  final StyleTable table;
  final List<int> blockIds;

  /// `runIds[i]` 是第 i 块的每个片段的样式 ID；没有片段的块为空列表。
  final List<List<int>> runIds;
}

abstract final class LegacyStyleAdapter {
  /// 按正文建一张表：块上没有样式输入，块全部用默认样式，只登记片段样式。
  ///
  /// 给「正文没有带样式表」的排版兜底用（`ChapterStyler.layoutTableOf`）。
  static LegacyStyleIds tableOf(ChapterContent content) =>
      buildTable(const [], content.blocks);

  /// 按块顺序把「每块的样式输入」翻译成样式记录，登记成一张去重的表。
  ///
  /// [inputs] 与 [blocks] 一一对应；缺的按默认样式（0 号记录）处理。片段的样式
  /// 不在这里翻译（片段仍带自己的文字样式字段），这里只登记。
  /// 返回的编号表用于回填 `styleId`（见 [ChapterStyler.attach]）。
  static LegacyStyleIds buildTable(
    List<BlockStyleInput?> inputs,
    List<ContentBlock> blocks,
  ) {
    final table = StyleTable();
    final blockIds = <int>[];
    final runIds = <List<int>>[];
    for (var i = 0; i < blocks.length; i++) {
      final block = blocks[i];
      final input = i < inputs.length ? inputs[i] : null;
      blockIds.add(table.intern(blockStyleOfSpec(input, block.kind)));
      runIds.add([for (final run in block.runs) table.intern(runStyleOf(run))]);
    }
    return LegacyStyleIds(table: table, blockIds: blockIds, runIds: runIds);
  }

  /// 按正文顺序展开的全部样式 ID（块与它内部的片段）。
  ///
  /// 几何摘要要用这个顺序：只改颜色时多出来的记录投影成空，摘要不变；
  /// 两个块互换样式时顺序变了，摘要会变。
  static List<int> orderedStyleIds(LegacyStyleIds ids) => [
    for (var i = 0; i < ids.blockIds.length; i++) ...[
      ids.blockIds[i],
      ...ids.runIds[i],
    ],
  ];

  /// 这一章的几何样式摘要，用来进测量断点身份。
  static String geometryDigest(LegacyStyleIds ids) =>
      ids.table.geometryDigestFor(orderedStyleIds(ids));

  /// 块级样式：对齐、首行缩进、盒子（背景/边框/圆角/阴影/内边距）、文字阴影、
  /// 列表标记类型、代码块的空白处理、字距词距、外边距、图片显式宽高。
  ///
  /// [kind] 单独传：代码块的 `white-space: pre` 是按块类型给的默认处理，不在样式输入里。
  /// 没有样式输入（null）时等价于「默认样式」，返回 [ComputedStyle.empty]。
  static ComputedStyle blockStyleOfSpec(
    BlockStyleInput? input,
    BlockKind kind,
  ) {
    final text = _textStyleOfSpec(input, kind);
    final box = _boxStyleOf(input?.box);
    final blockStyle = _blockStyleOfSpec(input);
    final size = _sizeStyleOfSpec(input);
    if (text.isEmpty && box.isEmpty && blockStyle.isEmpty && size.isEmpty) {
      return ComputedStyle.empty;
    }
    return ComputedStyle(text: text, box: box, block: blockStyle, size: size);
  }

  /// 图片显式宽高：旧字段是 `[数值, 单位]`（1 百分比、2 em、3 px，数值是单位的百分之一）。
  static SizeStyleSpec _sizeStyleOfSpec(BlockStyleInput? input) =>
      SizeStyleSpec(
        width: _imageLengthStyle(input?.imageWidth),
        maxWidth: _imageLengthStyle(input?.imageMaxWidth),
      );

  static Length? _imageLengthStyle(List<int>? spec) {
    if (spec == null || spec.length < 2) return null;
    final value = spec[0] / 100;
    return switch (spec[1]) {
      1 => PercentLength(spec[0] / 10000),
      2 => EmLength(value),
      3 => PxLength(value),
      _ => null,
    };
  }

  /// 片段样式：粗体/斜体/颜色/相对字号/上下标/下划线/删除线。
  ///
  /// 链接和脚注标记不是样式，留在正文模型上（它们参与交互和位置，不参与绘制属性）。
  static ComputedStyle runStyleOf(TextRun run) {
    final decoration = <TextDecorationLine>{
      if (run.underline) TextDecorationLine.underline,
      if (run.strike) TextDecorationLine.lineThrough,
    };
    final text = TextStyleSpec(
      fontWeight: run.bold ? FontWeightSpec.bold : null,
      fontStyle: run.italic ? FontStyleSpecValue.italic : null,
      color: run.color == null ? null : ColorValue(run.color!),
      fontSize: run.sizeScale == 1 ? null : RelativeFontSize(run.sizeScale),
      verticalAlign: run.superscript
          ? const VerticalAlignKeyword('super')
          : run.subscript
          ? const VerticalAlignKeyword('sub')
          : null,
      decoration: decoration.isEmpty
          ? null
          : TextDecorationSpec(lines: decoration),
    );
    return text.isEmpty ? ComputedStyle.empty : ComputedStyle(text: text);
  }

  /// 旧 JSON（块上还带样式字段）里每块的样式输入；新格式没有这些键，返回全是 null。
  ///
  /// 只有旧正文 JSON 解码需要它：块字段已经不在模型上，解码瞬间读出来直接建表。
  static List<BlockStyleInput?> inputsOfJson(Map<String, Object?> json) {
    final blocks = json['blocks'];
    if (blocks is! List) return const [];
    return [
      for (final raw in blocks)
        raw is Map
            ? BlockStyleInput.fromJson(raw.cast<String, Object?>())
            : null,
    ];
  }

  /// 旧字段口径的章节 JSON：从样式表把显示字段还原到块和片段上再序列化。
  ///
  /// 只用于**迁移期对照**（「同一份来源重新转换后，显示字段是否仍然逐项相同」，
  /// 见 `ContentFingerprint.legacyView`）。正文缓存的默认形态是 [ChapterContent.toJson]：
  /// 只有正文、结构和样式表。
  static Map<String, Object?> legacyJson(ChapterContent content) {
    final raw = content.stylesJson;
    final table = raw == null ? null : StyleTable.fromJson(raw);
    return {
      'chapterId': content.chapterId,
      if (content.pdfPage != null) 'pdfPage': content.pdfPage!.toJson(),
      if (content.epubDetailsRevision > 0)
        'epubDetailsRevision': content.epubDetailsRevision,
      'blocks': [
        for (final block in content.blocks) _legacyBlockJson(block, table),
      ],
      if (content.tables.isNotEmpty)
        'tables': [for (final table in content.tables) table.toJson()],
    };
  }

  static Map<String, Object?> _legacyBlockJson(
    ContentBlock block,
    StyleTable? table,
  ) {
    final style =
        table?[block.styleId ?? kDefaultStyleId] ?? ComputedStyle.empty;
    return {
      ...block.toJson(),
      ..._legacyBlockStyleJson(style),
      'runs': [
        for (final run in block.runs)
          _legacyRunJson(
            run,
            table?[run.styleId ?? kDefaultStyleId] ?? ComputedStyle.empty,
          ),
      ],
    };
  }

  /// 块级显示字段写回旧 JSON 键（顺序与旧版 `ContentBlock.toJson` 一致）。
  ///
  /// 用 [put] 逐个写入而不是 `if (x != null) 'k': x`：空值本来就不该出现在旧 JSON 里。
  static Map<String, Object?> _legacyBlockStyleJson(ComputedStyle style) {
    final json = <String, Object?>{};
    void put(String key, Object? value) {
      if (value != null) json[key] = value;
    }

    put('align', alignOf(style.block.textAlign));
    if (noIndentOf(style.block.textIndent)) put('noIndent', true);
    put('box', boxOf(style.box));
    put('tsh', shadowOf(style.text.shadow));
    put('list', listStyleOf(style.block.listStyle));
    put('mg', marginOf(style.block.margin));
    put('lsp', spacingOf(style.text.letterSpacing));
    put('wsp', spacingOf(style.text.wordSpacing));
    put('iw', imageLengthOf(style.size.width));
    put('imw', imageLengthOf(style.size.maxWidth));
    return json;
  }

  /// 片段显示字段写回旧 JSON 键（与 `TextRun.toJson` 一致）。
  static Map<String, Object?> _legacyRunJson(TextRun run, ComputedStyle style) {
    final decoration = style.text.decoration?.lines ?? const {};
    final vertical = style.text.verticalAlign;
    final sizeScale = switch (style.text.fontSize) {
      RelativeFontSize(:final factor) => factor,
      _ => 1.0,
    };
    final json = <String, Object?>{'text': run.text};
    void put(String key, Object? value) {
      if (value != null) json[key] = value;
    }

    if (style.text.fontWeight?.isBold ?? false) put('bold', true);
    if (style.text.fontStyle == FontStyleSpecValue.italic) put('italic', true);
    if (vertical is VerticalAlignKeyword && vertical.keyword == 'super') {
      put('sup', true);
    }
    if (vertical is VerticalAlignKeyword && vertical.keyword == 'sub') {
      put('sub', true);
    }
    put('c', style.text.color?.argb);
    if (sizeScale != 1) put('fs', sizeScale);
    if (decoration.contains(TextDecorationLine.underline)) put('u', true);
    if (decoration.contains(TextDecorationLine.lineThrough)) put('st', true);
    put('lk', run.link);
    if (run.footnote) put('fn', true);
    put('sid', run.styleId);
    return json;
  }

  /// 下面这些把计算样式翻回旧字段形状，排版层（`ResolvedBlockStyle`）与上面的
  /// 对照序列化共用同一套换算，避免两处各写一遍导致数值不一致。
  static String? alignOf(TextAlignSpec? align) => _restoreAlign(align);
  static bool noIndentOf(Length? indent) => _restoreNoIndent(indent);
  static int? listStyleOf(ListStyleSpec? list) => _restoreListStyle(list);
  static double? spacingOf(Length? value) => _restoreSpacing(value);
  static List<int>? boxOf(BoxStyleSpec box) => _restoreBox(box);
  static List<int>? marginOf(Edges? edges) => _restoreEdges(edges);
  static List<int>? shadowOf(List<ShadowValue>? shadow) =>
      _restoreShadow(shadow);
  static List<int>? imageLengthOf(Length? value) => _restoreImageLength(value);

  /// 外边距：四边都为空时不写；否则缺的边按 0 补齐（旧数组固定四个整数）。
  static List<int>? _restoreEdges(Edges? edges) {
    if (edges == null) return null;
    final values = [
      _hundredths(edges.top),
      _hundredths(edges.right),
      _hundredths(edges.bottom),
      _hundredths(edges.left),
    ];
    if (values.every((value) => value == 0)) return null;
    return values;
  }

  /// 字距／词距：样式表里是保留单位的长度，旧字段只有相对字号（em）。
  static double? _restoreSpacing(Length? value) => switch (value) {
    EmLength(:final value) => value,
    PxLength(:final value) => value / 16,
    _ => null,
  };

  /// 图片显式宽高：单位编码与 `ContentBlock.imageWidth` 的约定一致
  /// （1 百分比、2 em、3 px，数值是单位的百分之一）。
  static List<int>? _restoreImageLength(Length? value) => switch (value) {
    PercentLength(:final value) => [(value * 10000).round(), 1],
    EmLength(:final value) => [(value * 100).round(), 2],
    PxLength(:final value) => [(value * 100).round(), 3],
    _ => null,
  };

  static String? _restoreAlign(TextAlignSpec? align) => switch (align) {
    TextAlignSpec.center => 'center',
    TextAlignSpec.right => 'right',
    TextAlignSpec.left => 'left',
    _ => null,
  };

  /// 旧字段只有一个布尔：书里写了 `text-indent:0` 才是 true。
  static bool _restoreNoIndent(Length? indent) =>
      indent is PxLength && indent.value == 0;

  static int? _restoreListStyle(ListStyleSpec? list) => switch (list?.type) {
    ListStyleType.none => 0,
    ListStyleType.decimal => 1,
    ListStyleType.lowerAlpha => 2,
    ListStyleType.upperAlpha => 3,
    ListStyleType.lowerRoman => 4,
    ListStyleType.upperRoman => 5,
    ListStyleType.disc => 6,
    ListStyleType.circle => 7,
    ListStyleType.square => 8,
    _ => null,
  };

  /// 旧盒子数组的顺序与单位（百分之一 em）见 `ContentBlock.box` 的注释。
  static List<int>? _restoreBox(BoxStyleSpec box) {
    if (box.isEmpty) return null;
    final background = box.background?.color?.argb ?? 0;
    final border = box.border;
    final radii = box.radii;
    final shadow = box.shadow?.isNotEmpty == true ? box.shadow!.first : null;
    final padding = box.padding;
    int width(BorderSideSpec? side) => _hundredths(side?.width);
    int radius(Length? value) => _hundredths(value);
    int pad(Length? value) => _hundredths(value);
    return [
      background,
      width(border?.top),
      width(border?.right),
      width(border?.bottom),
      width(border?.left),
      border?.top?.color?.argb ?? 0,
      radius(radii?.topLeft),
      radius(radii?.topRight),
      radius(radii?.bottomRight),
      radius(radii?.bottomLeft),
      _hundredths(shadow?.offsetX),
      _hundredths(shadow?.offsetY),
      _hundredths(shadow?.blur),
      shadow?.color?.argb ?? 0,
      pad(padding?.top),
      pad(padding?.right),
      pad(padding?.bottom),
      pad(padding?.left),
      _borderStyleCode(border?.top?.style),
      _borderStyleCode(border?.right?.style),
      _borderStyleCode(border?.bottom?.style),
      _borderStyleCode(border?.left?.style),
    ];
  }

  static List<int>? _restoreShadow(List<ShadowValue>? shadow) {
    if (shadow == null || shadow.isEmpty) return null;
    final value = shadow.first;
    return [
      _hundredths(value.offsetX),
      _hundredths(value.offsetY),
      _hundredths(value.blur),
      value.color?.argb ?? 0,
    ];
  }

  static int _borderStyleCode(BorderLineStyle? style) => switch (style) {
    BorderLineStyle.dashed => 2,
    BorderLineStyle.dotted => 3,
    _ => 1,
  };

  /// 像素外的长度统一按 em 换回「百分之一 em」；新统一 CSS 会写入真实 px，
  /// 按 16px = 1em 折算，旧字段的 em 系数保持不变。
  static int _hundredths(Length? value) => switch (value) {
    EmLength(:final value) => (value * 100).round(),
    PercentLength(:final value) => (value * 100).round(),
    PxLength(:final value) => (value / 16 * 100).round(),
    _ => 0,
  };

  static TextStyleSpec _textStyleOfSpec(
    BlockStyleInput? input,
    BlockKind kind,
  ) {
    final shadow = input?.textShadow;
    final letterSpacing = input?.letterSpacing;
    final wordSpacing = input?.wordSpacing;
    return TextStyleSpec(
      shadow: shadow == null || shadow.length < 4
          ? null
          : [
              ShadowValue(
                offsetX: _em(shadow[0]),
                offsetY: _em(shadow[1]),
                blur: _em(shadow[2]),
                color: ColorValue(shadow[3]),
              ),
            ],
      // 代码块逐行测量、保留空白；这是引擎按块类型给的默认处理，
      // 样式表里对应 `white-space: pre`（标签默认表也登记了同一条）。
      whiteSpace: kind == BlockKind.codeBlock ? WhiteSpaceSpec.pre : null,
      // 字距／词距在旧字段里已经是相对字号的小数（0.05 表示 0.05em）。
      letterSpacing: letterSpacing == null ? null : EmLength(letterSpacing),
      wordSpacing: wordSpacing == null ? null : EmLength(wordSpacing),
    );
  }

  static BoxStyleSpec _boxStyleOf(List<int>? raw) {
    if (raw == null || raw.length < 18) return BoxStyleSpec.empty;
    final background = raw[0];
    final padding = _edges(raw[14], raw[15], raw[16], raw[17]);
    final border = _border(raw);
    final radii = _radii(raw);
    final shadow = _boxShadow(raw);
    if (background == 0 &&
        padding == null &&
        border == null &&
        radii == null &&
        shadow == null) {
      return BoxStyleSpec.empty;
    }
    return BoxStyleSpec(
      background: background == 0
          ? null
          : BackgroundSpec(color: ColorValue(background)),
      padding: padding,
      border: border,
      radii: radii,
      shadow: shadow,
    );
  }

  static BlockStyleSpec _blockStyleOfSpec(BlockStyleInput? input) {
    final listType = _listStyleType(input?.listStyle);
    return BlockStyleSpec(
      textAlign: switch (input?.align) {
        'center' => TextAlignSpec.center,
        'right' => TextAlignSpec.right,
        'left' => TextAlignSpec.left,
        _ => null,
      },
      // 书里明确写 text-indent:0 的块；没写时保留 null，让读者设置里的首行缩进生效。
      textIndent: input?.noIndent == true ? const PxLength(0) : null,
      listStyle: listType == null ? null : ListStyleSpec(type: listType),
      margin: _marginEdges(input?.margin),
    );
  }

  /// 四边外边距：旧字段是百分之一 em 的四个整数。
  static Edges? _marginEdges(List<int>? raw) {
    if (raw == null || raw.length < 4) return null;
    if (raw.every((value) => value == 0)) return null;
    return Edges(
      top: _em(raw[0]),
      right: _em(raw[1]),
      bottom: _em(raw[2]),
      left: _em(raw[3]),
    );
  }

  static BorderSpec? _border(List<int> raw) {
    final widths = [raw[1], raw[2], raw[3], raw[4]];
    if (widths.every((width) => width == 0)) return null;
    final styles = raw.length >= 22
        ? [raw[18], raw[19], raw[20], raw[21]]
        : const [1, 1, 1, 1];
    BorderSideSpec side(int index) => BorderSideSpec(
      width: widths[index] == 0 ? null : _em(widths[index]),
      style: _borderStyle(styles[index]),
      color: ColorValue(raw[5]),
    );
    return BorderSpec(
      top: side(0),
      right: side(1),
      bottom: side(2),
      left: side(3),
    );
  }

  static CornerRadii? _radii(List<int> raw) {
    final values = [raw[6], raw[7], raw[8], raw[9]];
    if (values.every((value) => value == 0)) return null;
    Length? radius(int value) => value == 0 ? null : _em(value);
    return CornerRadii(
      topLeft: radius(values[0]),
      topRight: radius(values[1]),
      bottomRight: radius(values[2]),
      bottomLeft: radius(values[3]),
    );
  }

  static List<ShadowValue>? _boxShadow(List<int> raw) {
    final x = raw[10], y = raw[11], blur = raw[12];
    if (x == 0 && y == 0 && blur == 0) return null;
    return [
      ShadowValue(
        offsetX: _em(x),
        offsetY: _em(y),
        blur: _em(blur),
        color: ColorValue(raw[13]),
      ),
    ];
  }

  static Edges? _edges(int top, int right, int bottom, int left) {
    if (top == 0 && right == 0 && bottom == 0 && left == 0) return null;
    return Edges(
      top: _em(top),
      right: _em(right),
      bottom: _em(bottom),
      left: _em(left),
    );
  }

  static BorderLineStyle? _borderStyle(int code) => switch (code) {
    1 => BorderLineStyle.solid,
    2 => BorderLineStyle.dashed,
    3 => BorderLineStyle.dotted,
    _ => null,
  };

  /// 列表标记编码（见 `ContentBlock.listStyle`）→ 样式表里的类型。
  static ListStyleType? _listStyleType(int? code) => switch (code) {
    0 => ListStyleType.none,
    1 => ListStyleType.decimal,
    2 => ListStyleType.lowerAlpha,
    3 => ListStyleType.upperAlpha,
    4 => ListStyleType.lowerRoman,
    5 => ListStyleType.upperRoman,
    6 => ListStyleType.disc,
    7 => ListStyleType.circle,
    8 => ListStyleType.square,
    _ => null,
  };

  /// 旧字段的长度单位是「百分之一 em」（见 `block_box_measure.dart` 的 `fontSize / 100`），
  /// 这里换成保留单位的 em 值，像素换算仍留给排版上下文。
  static Length _em(int hundredths) => EmLength(hundredths / 100);
}
