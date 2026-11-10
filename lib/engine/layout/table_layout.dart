import 'dart:math' as math;

import 'package:flutter/painting.dart';

import '../../domain/models/book_document.dart';
import '../../domain/models/content_table.dart';
import '../styles/style_table.dart';
import '../styles/style_value.dart';
import 'block_measure.dart';
import 'display_tree.dart';
import 'table_container_layout.dart';
import 'block_measurement_cache.dart';
import 'layout_options.dart';
import 'measured_block.dart';
import 'chapter_paginator.dart';
import 'parallel_flow_slices.dart';

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
  // 表格外面可能套着引用块：背景、左边框和内边距都属于这个盒子，
  // 表格内容要缩进到盒子内边距里，宽度也要相应减掉。
  final containers = TableContainerLayout.build(
    id,
    displayTree,
    styleTable,
    options,
    lastBlockId: table.blockIds.last,
  );
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

double tableHeight(List<MeasuredBlock> blocks) =>
    blocks.fold<double>(
      0.0,
      (height, block) => math.max(height, block.tableBounds!.bottom),
    ) +
    (blocks.first.isParallelFlow ? 0 : blocks.first.bodyBottom);

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
}) {
  if (blocks.first.isParallelFlow) {
    return parallelFlowFragments(blocks, from, to, y);
  }
  final result = <PageFragment>[];
  // 引用块里的表格：先放一个只用于画盒子的片段，背景和左右边框就能和
  // 表格前后的段落连成同一个引用框。它不参与文字、选区和位置。
  final box = blocks.first.tableBox;
  if (box != null || blocks.first.containerBoxes.isNotEmpty) {
    final tableEnd = tableHeight(blocks);
    final top = math.max(0.0, from);
    final bottom = math.min(tableEnd, to);
    if (bottom > top) {
      var left = double.infinity, right = 0.0;
      for (final block in blocks) {
        final bounds = block.tableBounds!;
        left = math.min(left, bounds.left);
        right = math.max(right, bounds.right);
      }
      final boxBlock = MeasuredBlock(
        blockId: '__table_box_${blocks.first.tableId ?? blocks.first.blockId}',
        containerBoxes: [
          for (final frame in blocks.first.containerBoxes)
            ContainerBoxFrame(
              elementId: frame.elementId,
              box: frame.box,
              first: frame.first && from <= 0.1,
              last: frame.last && to >= tableEnd - 0.1,
              left: frame.left,
              width: frame.width,
              top: from <= 0.1 ? frame.top : 0,
              bottom: to >= tableEnd - 0.1 ? frame.bottom : 0,
            ),
        ],
        kind: BlockKind.paragraph,
        height: bottom - top,
        inset: left,
        layoutWidth: math.max(1.0, right - left),
        box: box,
        boxId: blocks.first.boxId,
        // 整张表的第一页才画顶边，最后一页才画底边；中间页只有左右边。
        boxFirst: blocks.first.boxFirst && from <= 0.1,
        boxLast: blocks.first.boxLast && to >= tableEnd - 0.1,
        isDecoration: true,
        isTableBox: true,
      );
      result.add(
        PageFragment(
          block: boxBlock,
          lineFrom: 0,
          lineTo: 0,
          y: top - from + y,
          height: bottom - top,
          frameOnly: true,
        ),
      );
    }
  }
  final framed = <Rect>{};
  final singleCell = blocks.map((b) => b.tableBounds).toSet().length == 1;
  final authoredOuter = blocks.first.containerBoxes.any(
    (f) =>
        f.box.borderTop > 0 ||
        f.box.borderLeft > 0 ||
        f.box.borderBottom > 0 ||
        f.box.borderRight > 0,
  );
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
    if (framed.add(bounds) && !(singleCell && authoredOuter)) {
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
        ),
      );
    }
    if (block.imageSize != null) {
      if (block.tableTop >= from && block.tableTop < to) {
        result.add(PageFragment.whole(block, y: block.tableTop - from + y));
      }
      continue;
    }
    for (var i = 0; i < block.lines.length; i++) {
      final top = block.tableTop + i * block.tableUnit;
      // 文字行带居中于统一网格，末行在该行带剩余的半格留白中结束。
      if (top < from || top >= to) continue;
      result.add(
        PageFragment(
          block: block,
          lineFrom: i,
          lineTo: i + 1,
          y: top - from + y,
          height: block.lines[i].height,
        ),
      );
    }
  }
  return result;
}
