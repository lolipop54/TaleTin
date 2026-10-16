import 'dart:math' as math;

import 'package:flutter/painting.dart';

import '../../domain/models/book_document.dart';
import '../../domain/models/content_table.dart';
import 'block_measure.dart';
import 'block_measurement_cache.dart';
import 'layout_options.dart';
import 'measured_block.dart';
import 'chapter_paginator.dart';

/// 单元格仍由原有文字测量器测量；只改变宽度、字号和二维位置。
/// 同一张表使用统一行带，跨页按行带切开，不裁断文字。
List<MeasuredBlock> measureTable(
  ContentTable table,
  Map<String, ContentBlock> source,
  LayoutOptions options, {
  BlockMeasurementCache? cache,
}) {
  final id = table.blockIds.first;
  final columnWidth = options.contentWidth / table.columns;
  final fontSize = math.min(
    options.settings.fontSize,
    math.max(10, 24 - table.columns * 2),
  );
  final measured = <ContentTableCell, List<MeasuredBlock>>{};
  var unit = options.textScaler.scale(fontSize.toDouble()) * 1.4 + 8;
  for (final cell in table.cells) {
    final width = math.max(1.0, columnWidth * cell.columnSpan - 8);
    final settings = options.settings.copyWith(
      fontSize: fontSize,
      lineHeight: 1.4,
      indent: false,
    );
    final measurer = BlockMeasurer(
      LayoutOptions(
        settings: settings,
        contentSize: Size(width, math.max(1, options.contentHeight - unit)),
        textScaler: options.textScaler,
      ),
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
  final starts = <double>[0];
  for (final row in rows) {
    starts.add(starts.last + row * unit);
  }
  final result = <MeasuredBlock>[];
  for (final cell in table.cells) {
    final bounds = Rect.fromLTRB(
      cell.column * columnWidth,
      starts[cell.row],
      (cell.column + cell.columnSpan) * columnWidth,
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
        ),
      );
      top += (units(block) + 1) * unit;
    }
  }
  return result;
}

double tableHeight(List<MeasuredBlock> blocks) => blocks.fold(
  0.0,
  (height, block) => math.max(height, block.tableBounds!.bottom),
);

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
  double y,
) {
  final result = <PageFragment>[];
  final framed = <Rect>{};
  for (final block in blocks) {
    final bounds = block.tableBounds!;
    if (bounds.bottom <= from || bounds.top >= to) continue;
    final frame = Rect.fromLTRB(
      bounds.left,
      math.max(bounds.top, from) - from + y,
      bounds.right,
      math.min(bounds.bottom, to) - from + y,
    );
    if (framed.add(bounds)) {
      result.add(
        PageFragment(
          block: block,
          lineFrom: 0,
          lineTo: 0,
          y: frame.top,
          height: frame.height,
          tableFrame: frame,
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
