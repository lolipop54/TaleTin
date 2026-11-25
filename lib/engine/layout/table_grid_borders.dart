part of 'table_layout.dart';

/// 纯装饰表格复用正文表格的网格和绘制结果，只借用邻段作阅读锚点。
List<MeasuredBlock> measureEmptyGrid(
  ContentTable table,
  DisplayNode node,
  DisplayTree tree,
  StyleTable styles,
  LayoutOptions options,
) {
  final display = _tableForDisplay(table, tree, node);
  if (display.cells.isEmpty) return const [];
  final geometry = DisplayBoxLayout.resolve(
    tree.chainOfEmpty(node),
    styles,
    options,
    tree: tree,
    blockOwnerId: node.element.id,
  );
  final containers = TableContainerLayout(
    geometry.frames,
    geometry.left,
    geometry.right,
    geometry.top,
    geometry.bottom,
    geometry.containerHeight,
    geometry.marginReference,
  );
  return _measureStyledTable(
        display.table,
        tree.emptyGridBlocks,
        options,
        containers,
        styles,
        tree,
        null,
        display,
      ) ??
      const [];
}

/// 对表、列组、列、行组和行只登记外周。列 span 与行组边界来自原 DOM。
void _structuralBorders(
  CollapsedTableBorders grid,
  ContentTable table,
  _DisplayTable display,
  StyleTable styles,
  LayoutOptions options,
  double width,
) {
  Rect rect(int col, int row, int cols, int rows) => Rect.fromLTWH(
    (grid.rtl ? table.columns - col - cols : col).toDouble(),
    row.toDouble(),
    cols.toDouble(),
    rows.toDouble(),
  );
  void add(DisplayNode node, Rect bounds, TableBorderSource source) {
    final style = styles[node.element.styleId ?? 0];
    if (style.box.border == null) return;
    grid.add(
      -1,
      bounds,
      resolveBlockBox(
        style.box,
        DisplayBoxLayout.context(style, options, width),
        collapsedCell: true,
        tableColor: style.text.color?.argb,
      ),
      hiddenTableBorders(style.box.border),
      source: source,
    );
  }

  final root = display.element!;
  add(root, rect(0, 0, table.columns, table.rows), TableBorderSource.table);
  final groups = <DisplayNode, (int, int)>{};
  for (final (i, row) in display.rows.indexed) {
    add(row, rect(0, i, table.columns, 1), TableBorderSource.row);
    final group = row.parent;
    if (group != null && group != root) {
      groups[group] = (groups[group]?.$1 ?? i, i + 1);
    }
  }
  for (final entry in groups.entries) {
    final (first, end) = entry.value;
    add(
      entry.key,
      rect(0, first, table.columns, end - first),
      TableBorderSource.rowGroup,
    );
  }
  final columns = table.columnNodes;
  if (columns == null) return;
  final byNode = {
    for (final group in root.children.where(
      (n) => n.element.tag == 'colgroup' || n.element.tag == 'col',
    ))
      for (final node in [group, ...group.children]) node.element.nodeId: node,
  };
  final colGroups = <DisplayNode, (int, int)>{};
  for (var c = 0; c < math.min(columns.length, table.columns); c++) {
    final node = byNode[columns[c]];
    if (node == null) continue;
    if (node.element.tag == 'col') {
      add(node, rect(c, 0, 1, table.rows), TableBorderSource.column);
    }
    final group = node.element.tag == 'colgroup' ? node : node.parent;
    if (group != null && group.element.tag == 'colgroup') {
      colGroups[group] = (colGroups[group]?.$1 ?? c, c + 1);
    }
  }
  for (final entry in colGroups.entries) {
    final (first, end) = entry.value;
    add(
      entry.key,
      rect(first, 0, end - first, table.rows),
      TableBorderSource.columnGroup,
    );
  }
}

/// 网格负责合并边线；表盒只画底色、背景图和阴影。
BlockBox _tableBackdrop(BlockBox box) => BlockBox(
  background: box.background,
  backgroundImage: box.backgroundImage,
  borderColors: box.borderColors,
  borderTop: 0,
  borderRight: 0,
  borderBottom: 0,
  borderLeft: 0,
  borderRadius: box.borderRadius,
  radiusFractions: box.radiusFractions,
  shadows: box.shadows,
  padTop: 0,
  padRight: 0,
  padBottom: 0,
  padLeft: 0,
);

bool _hasCellContent(
  DisplayNode node,
  DisplayTree tree,
  StyleTable styles,
  List<_CellItem> items,
) {
  for (final item in items) {
    final block = item.block;
    if (block.imageSize != null || block.hasInlineImages) return true;
    final hidden =
        tree.hiddenText[tree.blockIndexById[block.blockId]] ?? const [];
    var start = 0;
    bool visibleText(int end) => block.text
        .substring(start, end.clamp(start, block.text.length))
        .contains(RegExp(r'[^ \t\r\n]'));
    // 隐藏的行内文本仍在原文中供定位。空格判定只看可见范围。
    for (final (from, to) in [
      ...hidden,
    ]..sort((a, b) => a.$1.compareTo(b.$1))) {
      if (from > start && visibleText(from)) return true;
      start = math.max(start, to).clamp(0, block.text.length);
    }
    if (visibleText(block.text.length)) return true;
  }
  bool space(DisplayNode n) {
    final value = tree.source?.cellSpaces[n.element.id];
    final white = styles[n.element.styleId ?? 0].text.whiteSpace;
    return value == true ||
        (value != null &&
            (white == WhiteSpaceSpec.pre || white == WhiteSpaceSpec.preWrap));
  }

  bool visible(DisplayNode child) =>
      !tree.hiddenElements.contains(child.element.id) &&
      (space(child) ||
          child.element.tag == 'br' ||
          (!child.anonymous && child.isBlock) ||
          child.children.any(visible));
  return space(node) || node.children.any(visible);
}
