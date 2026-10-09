/// 表格只补充现有正文块的行列关系，不重编号，进度和标注仍引用原块。
class ContentTable {
  const ContentTable(this.cells, this.columns, this.rows);
  final List<ContentTableCell> cells;
  final int columns, rows;
  Iterable<String> get blockIds => cells.expand((c) => c.blocks);
  Map<String, Object> toJson() => {
    'columns': columns,
    'rows': rows,
    'cells': cells.map((c) => c.toJson()).toList(),
  };
  factory ContentTable.fromJson(Map<String, dynamic> json) => ContentTable(
    (json['cells'] as List)
        .map(
          (c) => ContentTableCell.fromJson(Map<String, dynamic>.from(c as Map)),
        )
        .toList(),
    json['columns'] as int,
    json['rows'] as int,
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
