/// 样式表的「几何投影」：只保留会影响测量/分页的字段。
///
/// 为什么单独切一份：改一个文字颜色、背景色或圆角，不应该让整章重新测量；
/// 只有字号、行高、字距、对齐、缩进、边距、边框宽度、尺寸、列表标记、分页控制这些
/// 会改变行位置或块高矮的东西，才必须让测量断点失效。
///
/// 这份投影和 `style_registry.dart` 里每个属性的 `affectsGeometry` 标记是同一件事的两面：
/// 测试 `style_table_test.dart` 用注册表逐项核对，避免两边悄悄不一致。
library;

import 'style_box_value.dart';
import 'computed_style.dart';

/// 一个计算样式的几何投影（键与完整 JSON 保持同一套短名，便于对照）。
Map<String, Object?> geometryStyleJson(ComputedStyle style) => {
  if (_textHasGeometry(style.text)) 't': _textGeometry(style.text),
  if (_boxHasGeometry(style.box)) 'b': _boxGeometry(style.box),
  if (!style.block.isEmpty) 'k': _blockGeometry(style.block),
  if (!style.size.isEmpty) 's': _sizeGeometry(style.size),
  if (_tableHasGeometry(style.table)) 'tb': _tableGeometry(style.table),
};

/// 逐项写出会影响几何的文字字段。
///
/// - 字号、字重、斜体、行高、字距、词距、大小写、上下标、空白处理：改变行宽/行高/断行；
/// - 字体族在选用书内字体时影响几何。实际加载的字体字节另计入章节缓存键。
/// - 颜色、下划线/删除线、文字阴影只影响绘制。
Map<String, Object?> _textGeometry(TextStyleSpec text) => {
  if (text.fontSize != null) 'fs': text.fontSize!.toJson(),
  if (text.fontWeight != null) 'fw': text.fontWeight!.toJson(),
  if (text.fontStyle != null) 'fy': text.fontStyle!.name,
  if (text.fontFamilies != null) 'ff': text.fontFamilies,
  if (text.lineHeight != null) 'lh': text.lineHeight!.toJson(),
  if (text.letterSpacing != null) 'ls': text.letterSpacing!.toJson(),
  if (text.wordSpacing != null) 'ws': text.wordSpacing!.toJson(),
  if (text.textTransform != null) 'tt': text.textTransform!.name,
  if (text.verticalAlign != null) 'va': text.verticalAlign!.toJson(),
  if (text.whiteSpace != null) 'wsp': text.whiteSpace!.name,
};

bool _textHasGeometry(TextStyleSpec text) =>
    text.fontSize != null ||
    text.fontWeight != null ||
    text.fontStyle != null ||
    text.fontFamilies != null ||
    text.lineHeight != null ||
    text.letterSpacing != null ||
    text.wordSpacing != null ||
    text.textTransform != null ||
    text.verticalAlign != null ||
    text.whiteSpace != null;

/// 盒子只有内边距和边框**宽度**影响几何；颜色、线型、圆角、背景、阴影都只影响绘制。
Map<String, Object?> _boxGeometry(BoxStyleSpec box) => {
  if (box.padding != null) 'p': box.padding!.toJson(),
  'bw': ?_borderWidthsJson(box.border),
};

bool _boxHasGeometry(BoxStyleSpec box) =>
    box.padding != null || _borderWidthsJson(box.border) != null;

Map<String, Object?>? _borderWidthsJson(BorderSpec? border) {
  if (border == null || border.isEmpty) return null;
  final json = <String, Object?>{};
  if (border.top?.width != null) json['t'] = border.top!.width!.toJson();
  if (border.right?.width != null) json['r'] = border.right!.width!.toJson();
  final bottom = border.bottom?.width?.toJson();
  if (bottom != null) json['b'] = bottom;
  if (border.left?.width != null) json['l'] = border.left!.width!.toJson();
  return json.isEmpty ? null : json;
}

Map<String, Object?> _blockGeometry(BlockStyleSpec block) => {
  if (block.display != null) 'd': block.display!.name,
  if (block.textAlign != null) 'ta': block.textAlign!.name,
  if (block.textAlignLast != null) 'tal': block.textAlignLast!.name,
  if (block.textIndent != null) 'ti': block.textIndent!.toJson(),
  if (block.margin != null) 'm': block.margin!.toJson(),
  if (block.float != null) 'f': block.float!.name,
  if (block.clear != null) 'c': block.clear!.name,
  if (block.position != null) 'pos': block.position!.name,
  if (block.inset != null) 'in': block.inset!.toJson(),
  for (final entry in {
    'bb': block.breakBefore,
    'ba': block.breakAfter,
    'bi': block.breakInside,
  }.entries)
    if (entry.value != null) entry.key: entry.value,
  if (block.listStyle?.type != null) 'ls': {'t': block.listStyle!.type!.name},
  if (block.listStyle?.position != null) 'lsp': block.listStyle!.position!.name,
};

Map<String, Object?> _sizeGeometry(SizeStyleSpec size) => {
  if (size.width != null) 'w': size.width!.toJson(),
  if (size.height != null) 'h': size.height!.toJson(),
  if (size.minWidth != null) 'minw': size.minWidth!.toJson(),
  if (size.minHeight != null) 'minh': size.minHeight!.toJson(),
  if (size.maxWidth != null) 'maxw': size.maxWidth!.toJson(),
  if (size.maxHeight != null) 'maxh': size.maxHeight!.toJson(),
  if (size.boxSizing != null) 'bs': size.boxSizing!.name,
};

Map<String, Object?> _tableGeometry(TableStyleSpec table) => {
  if (table.borderCollapse != null) 'bc': table.borderCollapse,
  if (table.borderSpacing != null) 'bsp': table.borderSpacing!.toJson(),
  if (table.tableLayout != null) 'tl': table.tableLayout,
  if (table.captionSide != null) 'cs': table.captionSide,
};

bool _tableHasGeometry(TableStyleSpec table) =>
    table.borderCollapse != null ||
    table.borderSpacing != null ||
    table.tableLayout != null ||
    table.captionSide != null;
