import 'dart:math' as math;

import 'package:flutter/painting.dart';
import 'package:direct_read_rust/line_breaks.dart';

import '../../domain/models/book_document.dart';
import '../../domain/models/content_table.dart';
import '../styles/computed_style.dart';
import '../styles/style_table.dart';
import '../styles/style_box_value.dart';
import '../styles/style_value.dart';
import '../styles/tag_defaults.dart';
import 'block_measure.dart';
import 'box_size_resolver.dart';
import 'display_tree.dart';
import 'table_container_layout.dart';
import 'block_measurement_cache.dart';
import 'layout_options.dart';
import 'measured_block.dart';
import 'chapter_paginator.dart';
import 'parallel_flow_slices.dart';
import 'prose_line_breaks.dart';
import 'vertical_margins.dart';
import 'display_box_layout.dart';
import 'resolve_block_box.dart';
import 'collapsed_table_borders.dart';

part 'styled_table_layout.dart';
part 'table_column_layout.dart';
part 'table_character_alignment.dart';
part 'table_row_layout.dart';
part 'table_caption_layout.dart';
part 'table_grid_borders.dart';
part 'table_content_piece.dart';

/// 单元格仍由原有文字测量器测量；只改变宽度、字号和二维位置。
/// 同一张表使用统一行带，跨页按行带切开，不裁断文字。
/// 把原书列宽整理成「整张表宽为 1」的比例；没有可用宽度时返回 null。
List<double>? _columnFractions(
  ContentTable table,
  double width,
  LayoutOptions options,
  StyleTable? styles,
) {
  final raw = table.columnStyles == null
      ? table.columnWidths
      : [
          for (var i = 0; i < table.columnStyles!.length; i++)
            switch (styles?[table.columnStyles![i]].size.width) {
              null =>
                i < (table.columnWidths?.length ?? 0)
                    ? table.columnWidths![i]
                    : 0.0,
              final Length length =>
                length.isAuto
                    ? 0.0
                    : length.resolve(
                            LengthContext(
                              fontSize: options.settings.fontSize.toDouble(),
                              rootFontSize: options.settings.fontSize
                                  .toDouble(),
                              reference: width,
                            ),
                          ) /
                          width,
            },
        ];
  if (raw == null || raw.isEmpty) return null;
  final values = List<double>.filled(table.columns, 0);
  for (var i = 0; i < table.columns && i < raw.length; i++) {
    values[i] = raw[i].isFinite && raw[i] > 0 ? raw[i] : 0;
  }
  final specified = values.fold<double>(0, (sum, value) => sum + value);
  if (specified <= 0) return null;
  final blank = values.where((value) => value == 0).length;
  if (blank > 0 && specified < 1) {
    final share = (1 - specified) / blank;
    for (var i = 0; i < values.length; i++) {
      if (values[i] == 0) values[i] = share;
    }
  }
  // 原书 `table-layout:auto` 会把过窄的百分比列撑到至少放得下一个短单词。
  // 这里给每列一个下限（三列约 22%），再按比例缩放其余列，避免 14% 的
  // 首列把 "Query"／"Value"／"（查询）" 拆成两三行。
  final minimum = math.min(0.22, 0.66 / table.columns);
  for (var i = 0; i < values.length; i++) {
    values[i] = math.max(values[i], minimum);
  }
  final total = values.fold<double>(0, (sum, value) => sum + value);
  return total <= 0 ? null : [for (final value in values) value / total];
}

List<MeasuredBlock> measureTable(
  ContentTable table,
  Map<String, ContentBlock> source,
  LayoutOptions options, {
  BlockMeasurementCache? cache,
  StyleTable? styleTable,
  DisplayTree? displayTree,
  List<ContentBlock>? order,
}) {
  final id = table.blockIds.first;
  final display = _headerFirst(_tableForDisplay(table, displayTree));
  table = display.table;
  if (table.blockIds.isEmpty) return [];
  // 表格外面可能套着引用块：背景、左边框和内边距都属于这个盒子，
  // 表格内容要缩进到盒子内边距里，宽度也要相应减掉。
  final containers = TableContainerLayout.build(
    table.blockIds.first,
    displayTree,
    styleTable,
    options,
    lastBlockId: table.blockIds.last,
  );
  final styled = _measureStyledTable(
    table,
    source,
    options,
    containers,
    styleTable,
    displayTree,
    cache,
    display,
  );
  if (styled != null) return styled;
  final box = displayTree?.authoritative == true
      ? null
      : BlockBox.fromRaw(table.box, options.settings.fontSize.toDouble());
  final boxLeft = (box?.insetLeft ?? 0) + containers.left;
  final boxRight = (box?.insetRight ?? 0) + containers.right;
  final innerWidth = math.max(1.0, options.contentWidth - boxLeft - boxRight);
  // 表格在引用框里是不是第一块／最后一块：决定这一页要不要画顶边、底边。
  var boxFirst = false, boxLast = false;
  if (table.boxId != null && order != null) {
    final ids = table.blockIds.toSet();
    final firstIndex = order.indexWhere((block) => ids.contains(block.id));
    final lastIndex = order.lastIndexWhere((block) => ids.contains(block.id));
    if (firstIndex >= 0 && lastIndex >= 0) {
      final previous = firstIndex > 0 ? order[firstIndex - 1] : null;
      final next = lastIndex + 1 < order.length ? order[lastIndex + 1] : null;
      boxFirst = previous?.boxId != table.boxId;
      boxLast = next?.boxId != table.boxId;
    }
  }
  final columnWidth = innerWidth / table.columns;
  // 原书常用 `<col style="width:…%">` 让列不等宽（例如 14%／35%／49%）。
  // 没有列宽时才平均分；只给了部分列时，剩余列平分剩余宽度。
  final fractions = _columnFractions(table, innerWidth, options, styleTable);
  double columnEdge(int column) {
    if (fractions == null) return boxLeft + column * columnWidth;
    var x = boxLeft;
    for (var i = 0; i < column && i < fractions.length; i++) {
      x += innerWidth * fractions[i];
    }
    return x;
  }

  // 原书表格普遍声明 `table { font-size: 0.88em }`，手机宽度媒体查询里
  // 还有 0.82em；再叠加表格本身的紧凑排版，实际观感约为正文字号的 0.78。
  // 按 0.78 倍排，窄列里的短英文单词才放得下，再按列数封顶。
  final double fontSize = math.min(
    options.settings.fontSize * 0.78,
    math.max(10, 24 - table.columns * 2).toDouble(),
  );
  final measured = <ContentTableCell, List<MeasuredBlock>>{};
  var unit = options.textScaler.scale(fontSize.toDouble()) * 1.4 + 8;
  for (final cell in table.cells) {
    final cellWidth =
        columnEdge(cell.column + cell.columnSpan) - columnEdge(cell.column);
    final width = math.max(1.0, cellWidth - 8);
    final settings = options.settings.copyWith(
      fontSize: fontSize.round(),
      lineHeight: 1.4,
      indent: false,
    );
    final measurer = BlockMeasurer(
      LayoutOptions(
        settings: settings,
        contentSize: Size(width, math.max(1, options.contentHeight - unit)),
        textScaler: options.textScaler,
        insertChapterTitle: options.insertChapterTitle,
        publicationFonts: options.publicationFonts,
      ),
      styleTable: styleTable,
      // 单元格已经按表格列宽定位，不再叠加引用／列表的嵌套缩进。
      flatNest: true,
      tableBody: !cell.header,
      displayTree: displayTree,
      cache: cache,
    );
    measured[cell] = [
      for (final block in cell.blocks) measurer.measure(source[block]!),
    ];
    for (final block in measured[cell]!) {
      for (final line in block.lines) {
        unit = math.max(unit, line.height + 8);
      }
    }
  }
  int units(MeasuredBlock block) => block.lines.isNotEmpty
      ? block.lines.length
      : math.max(1, ((block.height + 8) / unit).ceil());
  final rows = List<int>.filled(table.rows, 1);
  // 先满足普通单元格，再让跨行单元格的末行承担尚缺的高度。
  final ordered = [...table.cells]
    ..sort((a, b) => a.rowSpan.compareTo(b.rowSpan));
  for (final cell in ordered) {
    final blocks = measured[cell]!;
    final int needed =
        blocks.fold<int>(0, (n, b) => n + units(b)) +
        math.max(0, blocks.length - 1);
    final available = rows
        .skip(cell.row)
        .take(cell.rowSpan)
        .fold<int>(0, (a, b) => a + b);
    if (needed > available) {
      rows[cell.row + cell.rowSpan - 1] += needed - available;
    }
  }
  final starts = <double>[containers.top];
  for (final row in rows) {
    starts.add(starts.last + row * unit);
  }
  final result = <MeasuredBlock>[];
  for (final cell in table.cells) {
    final bounds = Rect.fromLTRB(
      columnEdge(cell.column),
      starts[cell.row],
      columnEdge(cell.column + cell.columnSpan),
      starts[cell.row + cell.rowSpan],
    );
    var top = bounds.top + 4;
    final blocks = measured[cell]!;
    if (blocks.isEmpty) {
      result.add(
        MeasuredBlock(
          blockId: '__empty_${id}_${cell.row}_${cell.column}',
          kind: BlockKind.paragraph,
          isDecoration: true,
        ).inTable(
          id: id,
          bounds: bounds,
          top: top,
          unit: unit,
          header: cell.header,
          width: bounds.width - 8,
          containerBoxes: containers.frames,
          tableBottom: containers.bottom,
          tableBox: box,
          boxId: table.boxId,
          boxFirst: boxFirst,
          boxLast: boxLast,
        ),
      );
    }
    for (final block in blocks) {
      result.add(
        block.inTable(
          id: id,
          bounds: bounds,
          top: top,
          unit: unit,
          header: cell.header,
          width: bounds.width - 8,
          containerBoxes: containers.frames,
          tableBottom: containers.bottom,
          tableBox: box,
          boxId: table.boxId,
          boxFirst: boxFirst,
          boxLast: boxLast,
        ),
      );
      top += (units(block) + 1) * unit;
    }
  }
  return result;
}

typedef _DisplayTable = ({
  ContentTable table,
  DisplayNode? element,
  List<DisplayNode> rows,
  Map<ContentTableCell, DisplayNode> cells,
});

/// CSS 把首个 header-group 放到普通行之前。只换显示行号，保留单元格
/// 和块的来源顺序，因此原文搜索、摘录和已保存的位置沿用原来的块号。
_DisplayTable _headerFirst(_DisplayTable display) {
  final rows = display.rows;
  final start = rows.indexWhere(
    (r) => r.parent?.display == DisplaySpec.tableHeaderGroup,
  );
  if (start <= 0 || rows.length != display.table.rows) return display;
  var end = start + 1;
  while (end < rows.length && rows[end].parent == rows[start].parent) {
    end++;
  }
  final reordered = <ContentTableCell, DisplayNode>{};
  for (final entry in display.cells.entries) {
    final c = entry.key;
    final row = c.row < start
        ? c.row + end - start
        : c.row < end
        ? c.row - start
        : c.row;
    reordered[ContentTableCell(
          blocks: c.blocks,
          row: row,
          column: c.column,
          rowSpan: c.rowSpan,
          columnSpan: c.columnSpan,
          header: c.header,
          alignChar: c.alignChar,
          charOffset: c.charOffset,
        )] =
        entry.value;
  }
  final t = display.table;
  return (
    table: ContentTable(
      reordered.keys.toList(),
      t.columns,
      t.rows,
      box: t.box,
      boxId: t.boxId,
      columnWidths: t.columnWidths,
      columnWeights: t.columnWeights,
      columnNodes: t.columnNodes,
      columnStyles: t.columnStyles,
    ),
    element: display.element,
    rows: [
      ...rows.getRange(start, end),
      ...rows.take(start),
      ...rows.skip(end),
    ],
    cells: reordered,
  );
}

_DisplayTable _tableForDisplay(
  ContentTable table,
  DisplayTree? tree, [
  DisplayNode? empty,
]) {
  final original = (
    table: table,
    element: null,
    rows: const <DisplayNode>[],
    cells: const <ContentTableCell, DisplayNode>{},
  );
  final start = tree?.blockIndexById[table.blockIds.firstOrNull];
  if (tree == null || (empty == null && start == null)) return original;
  final element =
      empty?.element ??
      tree.source
          ?.chainOfBlock(start!)
          .where((element) => element.role == 'table')
          .firstOrNull;
  if (element == null) return original;
  final root = tree.nodes[element.id];
  final rows = <DisplayNode>[];
  final cells = <DisplayNode>[];
  void visit(DisplayNode node) {
    for (final child in node.children) {
      switch (child.element.role) {
        case 'table':
          continue;
        case 'row':
          rows.add(child);
          visit(child);
        case 'cell':
          cells.add(child);
        default:
          visit(child);
      }
    }
  }

  visit(root);
  if (cells.length != table.cells.length) return original;
  bool hidden(DisplayNode node) =>
      tree.hiddenElements.contains(node.element.id);
  if (!rows.any(hidden) && !cells.any(hidden)) {
    return (
      table: table,
      element: root,
      rows: rows,
      cells: {for (final (i, cell) in table.cells.indexed) cell: cells[i]},
    );
  }

  // 只重算画面中的行列。被隐藏的格子和行不再占位，正文块和原表格留给定位。
  final rowOffsets = [0];
  for (var i = 0; i < table.rows; i++) {
    rowOffsets.add(
      rowOffsets.last + (i < rows.length && hidden(rows[i]) ? 0 : 1),
    );
  }
  final occupiedUntil = <int, int>{};
  final visibleCells = <ContentTableCell, DisplayNode>{};
  var columns = 0;
  for (final (i, old) in table.cells.indexed) {
    if (hidden(cells[i])) continue;
    final row = rowOffsets[old.row];
    final end = rowOffsets[old.row + old.rowSpan];
    if (end <= row) continue;
    var column = 0;
    while (Iterable<int>.generate(
      old.columnSpan,
      (i) => column + i,
    ).any((col) => (occupiedUntil[col] ?? 0) > row)) {
      column++;
    }
    for (var c = column; c < column + old.columnSpan; c++) {
      occupiedUntil[c] = end;
    }
    columns = math.max(columns, column + old.columnSpan);
    visibleCells[ContentTableCell(
          blocks: old.blocks,
          row: row,
          column: column,
          rowSpan: end - row,
          columnSpan: old.columnSpan,
          header: old.header,
          alignChar: old.alignChar,
          charOffset: old.charOffset,
        )] =
        cells[i];
  }
  return (
    table: ContentTable(
      visibleCells.keys.toList(),
      columns,
      rowOffsets.last,
      box: table.box,
      boxId: table.boxId,
      columnWidths: table.columnWidths,
      columnWeights: table.columnWeights,
      columnNodes: table.columnNodes,
      columnStyles: table.columnStyles,
    ),
    element: root,
    rows: rows.where((row) => !hidden(row)).toList(),
    cells: visibleCells,
  );
}

double tableHeight(List<MeasuredBlock> blocks) =>
    blocks
        .where((b) => !b.positionedOverlay)
        .fold<double>(
          0.0,
          (height, block) => math.max(height, block.tableBounds!.bottom),
        ) +
    (blocks.first.isParallelFlow ? 0 : blocks.first.bodyBottom);

/// 滚动是连续的。分割绘制区域时，若目标切口切到字行或图片，
/// 就延长到所有相交内容的末端，位置本身不做任何换页位移。
Iterable<double> styledTableScrollCuts(
  List<MeasuredBlock> blocks,
  double height,
  double chunkHeight,
) sync* {
  final content = <({double top, double bottom})>[];
  for (final block in blocks) {
    for (final piece in tableContentPieces(block)) {
      content.add((top: piece.top, bottom: piece.top + piece.height));
    }
  }
  content.sort((a, b) => a.top.compareTo(b.top));
  var i = 0;
  var from = 0.0;
  while (from < height) {
    var end = math.min(height, from + chunkHeight);
    while (i < content.length && content[i].top < end - .00001) {
      end = math.max(end, content[i++].bottom);
    }
    yield end;
    from = end;
  }
}

/// 返回下一段能够完整显示的行带末端；图片作为整体换页。
double tableCut(List<MeasuredBlock> blocks, double from, double available) {
  final unit = blocks.first.tableUnit;
  var end = math.min(
    tableHeight(blocks),
    from + (available / unit).floor() * unit,
  );
  for (final block in blocks) {
    if (block.imageSize == null) continue;
    final top = block.tableTop - 4;
    final bottom = block.tableTop + block.height;
    if (top >= from && top < end && bottom > end) end = top;
  }
  return end;
}

List<PageFragment> tableFragments(
  List<MeasuredBlock> blocks,
  double from,
  double to,
  double y, {
  double? pageHeight,
  bool repeatedHeader = false,
}) {
  if (blocks.first.isParallelFlow) {
    return parallelFlowFragments(blocks, from, to, y);
  }
  final result = <PageFragment>[];
  // 引用块里的表格：先放一个只用于画盒子的片段，背景和左右边框就能和
  // 表格前后的段落连成同一个引用框。它不参与文字、选区和位置。
  final tableEnd = tableHeight(blocks);
  if (tableContainerFragment(
        blocks.first,
        tableHorizontalBounds(blocks),
        y,
        math.min(tableEnd, to) - from,
        first: from <= .01,
        last: to >= tableEnd - .01,
      )
      case final fragment?) {
    result.add(fragment);
  }
  final framed = <Rect>{};
  final singleCell = blocks.map((b) => b.tableBounds).toSet().length == 1;
  for (final block in blocks) {
    final bounds = block.tableBounds!;
    if (bounds.bottom <= from || bounds.top >= to) continue;
    final frame = Rect.fromLTRB(
      bounds.left,
      math.max(bounds.top, from) - from + y,
      bounds.right,
      bounds.bottom > to && pageHeight != null
          ? pageHeight
          : math.min(bounds.bottom, to) - from + y,
    );
    if (framed.add(bounds) &&
        tableNeedsCellFrame(block, singleCell: singleCell)) {
      result.add(
        PageFragment(
          block: block,
          lineFrom: 0,
          lineTo: 0,
          y: frame.top,
          height: frame.height,
          tableFrame: frame,
          tableTopEdge: bounds.top >= from,
          tableBottomEdge: bounds.bottom <= to,
          frameOnly: true,
          repeatedTableFrame: repeatedHeader,
        ),
      );
    }
    for (final piece in tableContentPieces(block)) {
      if (piece.top >= from - .00001 && piece.top < to - .00001) {
        result.add(piece.at(piece.top - from + y));
      }
    }
  }
  return result;
}

bool tableNeedsCellFrame(MeasuredBlock block, {required bool singleCell}) =>
    !singleCell ||
    block.tableCellBox != null ||
    block.collapsedTableBorders ||
    !block.containerBoxes.any(
      (f) =>
          f.box.borderTop > 0 ||
          f.box.borderRight > 0 ||
          f.box.borderBottom > 0 ||
          f.box.borderLeft > 0,
    );

({double left, double right}) tableHorizontalBounds(
  List<MeasuredBlock> blocks,
) {
  var left = double.infinity, right = 0.0;
  for (final block in blocks) {
    final bounds = block.tableBounds!;
    left = math.min(left, bounds.left);
    right = math.max(right, bounds.right);
  }
  return (left: left, right: right);
}

PageFragment? tableContainerFragment(
  MeasuredBlock block,
  ({double left, double right}) bounds,
  double y,
  double height, {
  required bool first,
  required bool last,
}) {
  final box = block.tableBox;
  if (height <= 0 || (box == null && block.containerBoxes.isEmpty)) return null;
  return PageFragment(
    block: MeasuredBlock(
      blockId: '__table_box_${block.tableId ?? block.blockId}',
      containerBoxes: [
        for (final frame in block.containerBoxes)
          ContainerBoxFrame(
            elementId: frame.elementId,
            box: frame.box,
            first: frame.first && first,
            last: frame.last && last,
            left: frame.left,
            width: frame.width,
            top: first ? frame.top : 0,
            bottom: last ? frame.bottom : 0,
          ),
      ],
      kind: BlockKind.paragraph,
      height: height,
      inset: bounds.left,
      layoutWidth: math.max(1, bounds.right - bounds.left),
      box: box,
      boxId: block.boxId,
      boxFirst: block.boxFirst && first,
      boxLast: block.boxLast && last,
      isDecoration: true,
      isTableBox: true,
    ),
    lineFrom: 0,
    lineTo: 0,
    y: y,
    height: height,
    frameOnly: true,
  );
}
