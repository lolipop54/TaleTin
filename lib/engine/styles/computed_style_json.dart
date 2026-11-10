/// 计算样式的 JSON 编解码：这是**正文缓存里的样式表格式**，也是 Rust 与 Dart 的契约。
///
/// 三条约定：
/// 1. **键短**：样式表会随正文一起进磁盘缓存（一章几十条记录），键名长短直接影响缓存体积，
///    所以这里用 2～4 个字符的短键；完整含义写在每个字段旁边，不靠猜。
/// 2. **null 不写**：字段为 null 表示「这一层没说过」，序列化时直接省略，读回来还是 null。
///    不能把 null 写成 0／normal，否则层叠语义就丢了。
/// 3. **不存派生值**：不存像素、不存行高乘数、不存「标题增量」这类引擎拼出来的东西；
///    只存作者那一侧的相对值，换字号／换纸面宽度后仍然可复用。
///
/// 版本：见 `styleSchemaVersion`（`style_table.dart`）。改了键名或语义就要递增，
/// 否则旧缓存会被当成新格式读。
library;

import 'computed_style.dart';
import 'style_box_value.dart';
import 'style_value.dart';

/// 文字样式。键：fs 字号、fw 字重、fy 字体风格、ff 字体族、c 颜色、lh 行高、
/// d 装饰、sh 阴影、ls 字距、ws 词距、tt 大小写、va 垂直对齐、wsp 空白、hy 断字。
Map<String, Object?> textSpecToJson(TextStyleSpec spec) => {
  if (spec.fontSize != null) 'fs': spec.fontSize!.toJson(),
  if (spec.fontWeight != null) 'fw': spec.fontWeight!.toJson(),
  if (spec.fontStyle != null) 'fy': spec.fontStyle!.name,
  if (spec.fontFamilies != null) 'ff': spec.fontFamilies,
  if (spec.fontFamilies == null && spec.legacyFontFamily != null)
    'ff': spec.legacyFontFamily,
  if (spec.color != null) 'c': spec.color!.toJson(),
  if (spec.lineHeight != null) 'lh': spec.lineHeight!.toJson(),
  if (spec.decoration != null) 'd': spec.decoration!.toJson(),
  if (spec.shadow != null)
    'sh': [for (final value in spec.shadow!) value.toJson()],
  if (spec.letterSpacing != null) 'ls': spec.letterSpacing!.toJson(),
  if (spec.wordSpacing != null) 'ws': spec.wordSpacing!.toJson(),
  if (spec.textTransform != null) 'tt': spec.textTransform!.name,
  if (spec.verticalAlign != null) 'va': spec.verticalAlign!.toJson(),
  if (spec.whiteSpace != null) 'wsp': spec.whiteSpace!.name,
  if (spec.hyphens != null) 'hy': spec.hyphens,
};

TextStyleSpec textSpecFromJson(Object? json) {
  if (json is! Map) return TextStyleSpec.empty;
  return TextStyleSpec(
    fontSize: fontSizeFromJson(json['fs']),
    fontWeight: FontWeightSpec.fromJson(json['fw']),
    fontStyle: _byName(FontStyleSpecValue.values, json['fy']),
    fontFamilies: switch (json['ff']) {
      final List families => List<String>.unmodifiable(families.cast<String>()),
      _ => null,
    },
    legacyFontFamily: json['ff'] is String ? json['ff'] as String : null,
    color: ColorValue.fromJson(json['c']),
    lineHeight: lineHeightFromJson(json['lh']),
    decoration: TextDecorationSpec.fromJson(json['d']),
    shadow: _shadowsFromJson(json['sh']),
    letterSpacing: lengthFromJson(json['ls']),
    wordSpacing: lengthFromJson(json['ws']),
    textTransform: _byName(TextTransformSpec.values, json['tt']),
    verticalAlign: verticalAlignFromJson(json['va']),
    whiteSpace: _byName(WhiteSpaceSpec.values, json['wsp']),
    hyphens: json['hy'] as String?,
  );
}

/// 盒子外观。键：p 内边距、b 边框、bg 背景、r 圆角、sh 阴影、o overflow。
Map<String, Object?> boxSpecToJson(BoxStyleSpec spec) => {
  if (spec.padding != null) 'p': spec.padding!.toJson(),
  if (spec.border != null) 'b': spec.border!.toJson(),
  if (spec.background != null) 'bg': spec.background!.toJson(),
  if (spec.radii != null) 'r': spec.radii!.toJson(),
  if (spec.shadow != null)
    'sh': [for (final value in spec.shadow!) value.toJson()],
  if (spec.overflow != null) 'o': spec.overflow,
};

BoxStyleSpec boxSpecFromJson(Object? json) {
  if (json is! Map) return BoxStyleSpec.empty;
  return BoxStyleSpec(
    padding: Edges.fromJson(json['p']),
    border: BorderSpec.fromJson(json['b']),
    background: BackgroundSpec.fromJson(json['bg']),
    radii: CornerRadii.fromJson(json['r']),
    shadow: _shadowsFromJson(json['sh']),
    overflow: json['o'] as String?,
  );
}

/// 块级样式。键：d display、ta/tal 对齐、ti 首行缩进、m 外边距、f 浮动、c 清除、
/// pos 定位、bb/ba/bi 分页、ls 列表。
Map<String, Object?> blockSpecToJson(BlockStyleSpec spec) => {
  if (spec.display != null) 'd': spec.display!.name,
  if (spec.textAlign != null) 'ta': spec.textAlign!.name,
  if (spec.textAlignLast != null) 'tal': spec.textAlignLast!.name,
  if (spec.textIndent != null) 'ti': spec.textIndent!.toJson(),
  if (spec.margin != null) 'm': spec.margin!.toJson(),
  if (spec.float != null) 'f': spec.float!.name,
  if (spec.clear != null) 'c': spec.clear!.name,
  if (spec.position != null) 'pos': spec.position!.name,
  if (spec.inset != null) 'in': spec.inset!.toJson(),
  if (spec.breakBefore != null) 'bb': spec.breakBefore,
  if (spec.breakAfter != null) 'ba': spec.breakAfter,
  if (spec.breakInside != null) 'bi': spec.breakInside,
  if (spec.listStyle != null) 'ls': spec.listStyle!.toJson(),
};

BlockStyleSpec blockSpecFromJson(Object? json) {
  if (json is! Map) return BlockStyleSpec.empty;
  return BlockStyleSpec(
    display: _byName(DisplaySpec.values, json['d']),
    textAlign: _byName(TextAlignSpec.values, json['ta']),
    textAlignLast: _byName(TextAlignSpec.values, json['tal']),
    textIndent: lengthFromJson(json['ti']),
    margin: Edges.fromJson(json['m']),
    float: _byName(FloatSpec.values, json['f']),
    clear: _byName(ClearSpec.values, json['c']),
    position: _byName(PositionSpec.values, json['pos']),
    inset: Edges.fromJson(json['in']),
    breakBefore: json['bb'] as String?,
    breakAfter: json['ba'] as String?,
    breakInside: json['bi'] as String?,
    listStyle: ListStyleSpec.fromJson(json['ls']),
  );
}

/// 尺寸。键：w/h 宽高、minw/minh 最小、maxw/maxh 最大、bs 盒模型、of 图片缩放方式。
Map<String, Object?> sizeSpecToJson(SizeStyleSpec spec) => {
  if (spec.width != null) 'w': spec.width!.toJson(),
  if (spec.height != null) 'h': spec.height!.toJson(),
  if (spec.minWidth != null) 'minw': spec.minWidth!.toJson(),
  if (spec.minHeight != null) 'minh': spec.minHeight!.toJson(),
  if (spec.maxWidth != null) 'maxw': spec.maxWidth!.toJson(),
  if (spec.maxHeight != null) 'maxh': spec.maxHeight!.toJson(),
  if (spec.boxSizing != null) 'bs': spec.boxSizing!.name,
  if (spec.objectFit != null) 'of': spec.objectFit,
};

SizeStyleSpec sizeSpecFromJson(Object? json) {
  if (json is! Map) return SizeStyleSpec.empty;
  return SizeStyleSpec(
    width: lengthFromJson(json['w']),
    height: lengthFromJson(json['h']),
    minWidth: lengthFromJson(json['minw']),
    minHeight: lengthFromJson(json['minh']),
    maxWidth: lengthFromJson(json['maxw']),
    maxHeight: lengthFromJson(json['maxh']),
    boxSizing: _byName(BoxSizingSpec.values, json['bs']),
    objectFit: json['of'] as String?,
  );
}

/// 表格。键：bc 合并边框、bsp 边框间距、tl 布局算法、cs 标题位置、ec 空单元格。
Map<String, Object?> tableSpecToJson(TableStyleSpec spec) => {
  if (spec.borderCollapse != null) 'bc': spec.borderCollapse,
  if (spec.borderSpacing != null) 'bsp': spec.borderSpacing!.toJson(),
  if (spec.tableLayout != null) 'tl': spec.tableLayout,
  if (spec.captionSide != null) 'cs': spec.captionSide,
  if (spec.emptyCells != null) 'ec': spec.emptyCells,
};

TableStyleSpec tableSpecFromJson(Object? json) {
  if (json is! Map) return TableStyleSpec.empty;
  return TableStyleSpec(
    borderCollapse: json['bc'] as String?,
    borderSpacing: lengthFromJson(json['bsp']),
    tableLayout: json['tl'] as String?,
    captionSide: json['cs'] as String?,
    emptyCells: json['ec'] as String?,
  );
}

/// 一个元素的完整计算样式。键：t 文字、b 盒子、k 块级、s 尺寸、tb 表格、x 诊断。
///
/// `x`（书里出现了但没登记的属性）**不进正式缓存**：它只用于开发期诊断，
/// 由调用方决定是否带上，避免把几百个无关属性写进磁盘。
Map<String, Object?> computedStyleToJson(
  ComputedStyle style, {
  bool includeExtras = false,
}) {
  final json = <String, Object?>{};
  if (!style.text.isEmpty) json['t'] = textSpecToJson(style.text);
  if (!style.box.isEmpty) json['b'] = boxSpecToJson(style.box);
  if (!style.block.isEmpty) json['k'] = blockSpecToJson(style.block);
  if (!style.size.isEmpty) json['s'] = sizeSpecToJson(style.size);
  if (!style.table.isEmpty) json['tb'] = tableSpecToJson(style.table);
  if (includeExtras && style.extras.isNotEmpty) {
    json['x'] = Map<String, String>.from(style.extras);
  }
  return json;
}

ComputedStyle computedStyleFromJson(Object? json) {
  if (json is! Map) return ComputedStyle.empty;
  return ComputedStyle(
    text: textSpecFromJson(json['t']),
    box: boxSpecFromJson(json['b']),
    block: blockSpecFromJson(json['k']),
    size: sizeSpecFromJson(json['s']),
    table: tableSpecFromJson(json['tb']),
    extras: {
      for (final entry in (json['x'] as Map? ?? const {}).entries)
        entry.key as String: entry.value as String,
    },
  );
}

List<ShadowValue>? _shadowsFromJson(Object? json) {
  if (json is! List) return null;
  final result = <ShadowValue>[];
  for (final item in json) {
    final value = ShadowValue.fromJson(item);
    if (value != null) result.add(value);
  }
  return result.isEmpty ? null : result;
}

T? _byName<T extends Enum>(List<T> values, Object? name) {
  for (final value in values) {
    if (value.name == name) return value;
  }
  return null;
}
