/// 表格只补充现有正文块的行列关系，不重编号，进度和标注仍引用原块。
class ContentTable {
  const ContentTable(
    this.cells,
    this.columns,
    this.rows, {
    this.box,
    this.boxId,
    this.columnWidths,
    this.columnNodes,
    this.columnStyles,
  });

  final List<ContentTableCell> cells;
  final int columns, rows;

  /// 原书写明的列宽，按列顺序的相对值（1 表示整张表宽）。
  ///
  /// 来自 `<colgroup><col style="width: 14%">`；没有写宽度的列为 0，排版时
  /// 用剩余宽度平均补齐。旧正文没有该字段时退回平均分栏。
  final List<double>? columnWidths;

  /// 列元素的来源节点／当前样式引用；不参与正文统计。
  final List<int>? columnNodes;
  final List<int>? columnStyles;

  /// 表格外层容器（如引用块）的盒子：背景、边框、圆角和内边距。
  ///
  /// 原书的表格可能整个包在 `blockquote` 里，背景和左边框属于引用块。
  /// 这个字段只用于显示，不参与文字、位置和进度计算；旧缓存没有它时按无盒子排。
  final List<int>? box;
  final int? boxId;

  Iterable<String> get blockIds => cells.expand((c) => c.blocks);

  /// 只含行列结构与「单元格 → 块 ID」的正文口径；外层引用框是显示字段，不进来。
  ///
  /// 正文摘要与不变量基线都用它，避免以后再加背景、边框时又让整章正文摘要变化。
  List<Object?> toBodyJson() => [
    columns,
    rows,
    for (final cell in cells)
      [
        cell.blocks,
        cell.row,
        cell.column,
        cell.rowSpan,
        cell.columnSpan,
        cell.header,
      ],
  ];

  Map<String, Object> toJson() => {
    'columns': columns,
    'rows': rows,
    'cells': cells.map((c) => c.toJson()).toList(),
    'box': ?box,
    'boxId': ?boxId,
    'colw': ?columnWidths,
    'colnodes': ?columnNodes,
    'colstyles': ?columnStyles,
  };

  factory ContentTable.fromJson(Map<String, dynamic> json) => ContentTable(
    (json['cells'] as List)
        .map(
          (c) => ContentTableCell.fromJson(Map<String, dynamic>.from(c as Map)),
        )
        .toList(),
    json['columns'] as int,
    json['rows'] as int,
    box: (json['box'] as List?)?.cast<int>(),
    boxId: (json['boxId'] as num?)?.toInt(),
    columnNodes: (json['colnodes'] as List?)?.cast<int>(),
    columnStyles: (json['colstyles'] as List?)?.cast<int>(),
    columnWidths: json['colw'] == null
        ? null
        : [for (final value in json['colw'] as List) (value as num).toDouble()],
  );
}

class ContentTableCell {
  const ContentTableCell({
    required this.blocks,
    required this.row,
    required this.column,
    this.rowSpan = 1,
    this.columnSpan = 1,
    this.header = false,
  });
  final List<String> blocks;
  final int row, column, rowSpan, columnSpan;
  final bool header;
  Map<String, Object> toJson() => {
    'blocks': blocks,
    'row': row,
    'column': column,
    'rowSpan': rowSpan,
    'columnSpan': columnSpan,
    'header': header,
  };
  factory ContentTableCell.fromJson(Map<String, dynamic> json) =>
      ContentTableCell(
        blocks: (json['blocks'] as List).cast<String>(),
        row: json['row'] as int,
        column: json['column'] as int,
        rowSpan: json['rowSpan'] as int,
        columnSpan: json['columnSpan'] as int,
        header: json['header'] as bool,
      );
}
