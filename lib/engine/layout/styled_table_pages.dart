import 'dart:math' as math;
import 'dart:ui';

import 'chapter_paginator.dart';
import 'measured_block.dart';
import 'table_layout.dart';
import 'table_page_space.dart';
import 'collapsed_table_borders.dart';

part 'table_span_fragments.dart';

typedef StyledTableSlice = ({
  int page,
  double bottom,
  List<PageFragment> fragments,
  List<PageFragment> repeatedHeader,
});

const _epsilon = .00001;

/// 将有作者样式的表格排入实际页面。可以放进一页的整行优先保持完整；
/// 超高行的各格独立断行。某个格子为换页让出的空间由共享行底接收，
/// 后续行统一顺延，避免一列先进入下一行而与邻格错位。
Iterable<StyledTableSlice> styledTablePages(
  List<MeasuredBlock> blocks,
  double firstY,
  double pageHeight,
) sync* {
  final byBounds = <Rect, List<MeasuredBlock>>{};
  for (final block in blocks) {
    (byBounds[block.tableBounds!] ??= []).add(block);
  }
  final cells =
      byBounds.entries.map((e) => (bounds: e.key, blocks: e.value)).toList()
        ..sort((a, b) {
          final row = a.bounds.top.compareTo(b.bounds.top);
          return row != 0 ? row : a.bounds.left.compareTo(b.bounds.left);
        });
  final rows = blocks.first.tableBreakRows;
  final rowIndex = {for (final (i, r) in rows.indexed) r.top: i};
  final horizontal = tableHorizontalBounds(blocks);
  final pages = <int, List<PageFragment>>{};
  final space = TablePageSpace(pageHeight);
  final pageOf = space.pageOf, pageTop = space.top, pageEnd = space.end;
  final header = blocks.first.tableHeaderBand;
  final repeat =
      header != null &&
      header.bottom > header.top &&
      header.bottom - header.top <= pageHeight / 4 + _epsilon &&
      header.bodyTop - header.top < pageHeight;
  late final copies = tableFragments(
    blocks
        .where(
          (b) =>
              b.tableBounds!.top >= header!.top &&
              b.tableBounds!.bottom <= header.bottom,
        )
        .toList(),
    header!.top,
    header.bottom,
    0,
    repeatedHeader: true,
  ).where((f) => !f.block.isTableBox).toList(growable: false);
  final initialPage = pageOf(firstY);
  var nextPage = initialPage;
  var tableStart = firstY;
  var originalEnd = 0.0;
  var updatedEnd = firstY;

  // 相邻行恰好分到两页时，共享横线由前页画到网格末端。后一行的落点
  // 要等真正排过这一行才知道，因此在交出前页时登记绘制标记。
  final breaks = <double, (int, int, bool)>{};
  double? previousGridEnd;
  var previousPage = initialPage;
  final hasHorizontal = blocks.any((b) => b.tableHorizontalBorders.isNotEmpty);
  void recordBreak(
    double top,
    double actualTop,
    double end,
    double bottom, {
    bool insideSpan = false,
  }) {
    if (!hasHorizontal) return;
    final page = pageOf(actualTop);
    if (previousGridEnd == top && previousPage < page) {
      breaks[top] = (previousPage, page, insideSpan);
    }
    previousGridEnd = end;
    previousPage = pageOf(bottom - 2 * _epsilon);
  }

  PageFragment gridBreak(PageFragment f, int page) {
    final bounds = f.block.tableBounds;
    if (breaks.isEmpty ||
        bounds == null ||
        f.paintedTableFrame == null ||
        !f.block.collapsedTableBorders) {
      return f;
    }
    final atTop = breaks[bounds.top];
    final omit =
        f.tableTopEdge && atTop != null && atTop.$2 == page && atTop.$3;
    final clip = f.tableBottomEdge && breaks[bounds.bottom]?.$1 == page;
    return omit || clip ? f.withGridBreak(omitTop: omit, clipBottom: clip) : f;
  }

  StyledTableSlice finish(int page, double end, {required bool last}) {
    final top = math.max(0.0, tableStart - pageTop(page));
    final bottom = space.local(end, page);
    final container = tableContainerFragment(
      blocks.first,
      horizontal,
      top,
      bottom - top,
      first: page == pageOf(tableStart),
      last: last,
    );
    final placed = pages.remove(page) ?? const <PageFragment>[];
    return (
      page: page,
      bottom: bottom,
      repeatedHeader: space.repeats(page) ? copies : const [],
      fragments: [
        ?container,
        if (breaks.isEmpty)
          ...placed
        else
          for (final f in placed) gridBreak(f, page),
      ],
    );
  }

  for (var index = 0; index < cells.length;) {
    // 跨行格把相交的行连成一个整体；没有跨行格的普通行可单独移动。
    final first = index;
    final top = cells[index].bounds.top;
    var end = cells[index++].bounds.bottom;
    while (index < cells.length && cells[index].bounds.top < end - _epsilon) {
      end = math.max(end, cells[index++].bounds.bottom);
    }
    final gap = top - originalEnd;
    var start = math.max(0.0, updatedEnd + gap);
    final height = end - top;
    final gridIndex = rowIndex[top];
    var groupEnd = gridIndex == null ? null : rows[gridIndex].avoidUntil;
    if (repeat && top == header.top) {
      // 首页至少容纳表头及下一行开头。否则表头与正文一起移页。
      final body = cells.firstWhere((c) => c.bounds.top >= header.bodyTop);
      final firstLine = body.blocks.expand(tableContentPieces).firstOrNull;
      final row = rowIndex[header.bodyTop];
      final rowBottom = row == null ? body.bounds.bottom : rows[row].bottom;
      final groupBottom = row == null
          ? rowBottom
          : rows[row].avoidUntil ?? rowBottom;
      groupEnd = groupBottom - header.top <= pageHeight
          ? groupBottom
          : rowBottom - header.top <= pageHeight
          ? rowBottom
          : math.min(
              header.top + pageHeight,
              firstLine == null
                  ? header.bodyTop
                  : firstLine.top + firstLine.height,
            );
    }
    final firstBody =
        repeat && top == header.bodyTop && pageOf(start) < space.repeatFrom!;
    final moveGroup =
        !firstBody &&
        groupEnd != null &&
        start + groupEnd - top > pageEnd(pageOf(start)) + _epsilon;
    var leadingGap = gap;
    // 避断行组先尝试从整张纸开始。大于一页时只在组首尝试一次，组内按行续排。
    if (moveGroup ||
        (height <= space.capacity(pageOf(start) + 1) + _epsilon &&
            start + height > pageEnd(pageOf(start)) + _epsilon)) {
      final startPage = pageOf(start);
      final capacity = space.capacity(startPage + 1);
      final wanted = moveGroup ? math.min(capacity, groupEnd - top) : height;
      leadingGap = math.min(gap, math.max(0.0, capacity - wanted));
      final freshPage = updatedEnd <= pageTop(startPage) + _epsilon;
      start =
          (freshPage ? pageTop(startPage) : pageEnd(startPage)) + leadingGap;
    }
    if (first == 0 && pageOf(start) > initialPage && gap < pageHeight) {
      tableStart = math.max(firstY, start - leadingGap);
      nextPage = pageOf(tableStart);
    }
    if (repeat && top == header.top) {
      space.repeatFrom = pageOf(start) + 1;
      space.reserved = header.bodyTop - header.top;
    }
    final band = cells.sublist(first, index);

    late final starts = <Rect, double>{};
    late final ends = <Rect, double>{};
    final content = <Rect, List<({int page, PageFragment fragment})>>{};
    late final rowEnds = <double, double>{};
    late final rowShifts = <double, double>{};
    late final slackBefore = <double, double>{};
    double placeCell(
      Rect bounds,
      List<MeasuredBlock> cellBlocks,
      double cellShift,
    ) {
      final placed = <({int page, PageFragment fragment})>[];
      content[bounds] = placed;
      var delay = 0.0;
      for (final block in cellBlocks) {
        for (final piece in tableContentPieces(block)) {
          var y = piece.top + cellShift + delay;
          final page = pageOf(y);
          final remaining = pageEnd(page) - y;
          // 本格下一行接着本格的上一次断点，邻格的短文字不会在续页重放。
          if (piece.height > remaining + _epsilon &&
              y > pageTop(page) + _epsilon) {
            delay += remaining;
            y = pageEnd(page);
          }
          final target = pageOf(y);
          placed.add((
            page: target,
            fragment: piece.at(space.local(y, target)),
          ));
        }
      }
      // 短列换页让出的高度先由格内已有的空白吸收。只有实际内容和底部
      // 内边距超出原行底时才推迟下一行。
      final contentEnd = cellBlocks.first.tableContentBottom ?? bounds.bottom;
      return contentEnd + cellShift + delay;
    }

    var slack = 0.0;
    var shift = start - top;
    final simpleRow = gridIndex == null
        ? band.every((c) => c.bounds.top == top && c.bounds.bottom == end)
        : rows[gridIndex].bottom >= end - _epsilon;
    var commonBottom = end + shift;
    if (simpleRow) {
      for (final cell in band) {
        commonBottom = math.max(
          commonBottom,
          placeCell(cell.bounds, cell.blocks, shift),
        );
      }
      recordBreak(top, start, end, commonBottom);
      shift = commonBottom - end;
    } else {
      final byBottom = [...band]
        ..sort((a, b) => a.bounds.bottom.compareTo(b.bounds.bottom));
      var cellIndex = 0;
      final bandRows = <TableBreakRow>[];
      if (gridIndex != null) {
        for (
          var r = gridIndex;
          r < rows.length && rows[r].top < end - _epsilon;
          r++
        ) {
          bandRows.add(rows[r]);
        }
      }
      if (bandRows.isEmpty) {
        // 旧的调用方可能只传单元格矩形。相交的矩形仍提供每条内部行边界。
        final points = {
          for (final c in band) ...[c.bounds.top, c.bounds.bottom],
        }.toList()..sort();
        for (var i = 1; i < points.length; i++) {
          bandRows.add((
            top: points[i - 1],
            bottom: points[i],
            avoidUntil: null,
          ));
        }
      }

      for (final line in bandRows) {
        final rowEnd = line.bottom;
        final rowStart = line.top + shift;
        final h = rowEnd - line.top;
        if (line.top > top &&
            h <= space.capacity(pageOf(rowStart) + 1) + _epsilon &&
            rowStart + h > pageEnd(pageOf(rowStart)) + _epsilon) {
          final moved = pageEnd(pageOf(rowStart));
          slack += moved - rowStart;
          shift += moved - rowStart;
        }
        rowShifts[line.top] = shift;
        slackBefore[line.top] = slack;
        var rowBottom = rowEnd + shift;
        final firstEnding = cellIndex;
        while (cellIndex < byBottom.length &&
            byBottom[cellIndex].bounds.bottom <= rowEnd + _epsilon) {
          final cell = byBottom[cellIndex++];
          final cellShift = rowShifts[cell.bounds.top]!;
          starts[cell.bounds] = cell.bounds.top + cellShift;
          final requiredBottom = placeCell(cell.bounds, cell.blocks, cellShift);
          rowBottom = math.max(rowBottom, requiredBottom);
          ends[cell.bounds] = requiredBottom;
        }
        for (var j = firstEnding; j < cellIndex; j++) {
          final bounds = byBottom[j].bounds;
          // 邻列整行移页的空档已包含在跨行格从上一页延伸的部分中；
          // 格子自己的内容和内边距仍必须装得下。
          ends[bounds] = math.max(
            ends[bounds]!,
            rowBottom - (slack - slackBefore[bounds.top]!),
          );
        }
        recordBreak(
          line.top,
          line.top + shift,
          rowEnd,
          rowBottom,
          insideSpan: line.top > top,
        );
        rowEnds[rowEnd] = rowBottom;
        shift = rowBottom - rowEnd;
      }
    }
    for (final cell in band) {
      final cellTop = simpleRow ? top + (start - top) : starts[cell.bounds]!;
      final cellBottom = simpleRow ? commonBottom : ends[cell.bounds]!;
      final lastPage = pageOf(cellBottom - 2 * _epsilon);
      final firstPage = pageOf(cellTop);
      final frameNeeded = tableNeedsCellFrame(
        cell.blocks.first,
        singleCell: cells.length == 1,
      );
      final row = rowIndex[cell.bounds.top];
      final splitSpan =
          row != null &&
          rows[row].bottom < cell.bounds.bottom - _epsilon &&
          cell.blocks.first.collapsedTableBorders &&
          pageOf(rowEnds[cell.bounds.bottom]! - 2 * _epsilon) > firstPage;
      if (frameNeeded && splitSpan) {
        for (final (p, frame) in _splitSpanFrames(
          cell.blocks.first,
          rows,
          row,
          rowShifts,
          rowEnds,
          cellTop,
          cellBottom,
          space,
        )) {
          (pages[p] ??= []).add(frame);
        }
      }
      for (var p = firstPage; frameNeeded && !splitSpan && p <= lastPage; p++) {
        final frame = Rect.fromLTRB(
          cell.bounds.left,
          space.local(math.max(cellTop, pageTop(p)), p),
          cell.bounds.right,
          space.local(math.min(cellBottom, pageEnd(p)), p),
        );
        (pages[p] ??= []).add(
          PageFragment(
            block: cell.blocks.first,
            lineFrom: 0,
            lineTo: 0,
            y: frame.top,
            height: frame.height,
            tableFrame: frame,
            tableTopEdge: p == firstPage,
            tableBottomEdge: p == lastPage,
            frameOnly: true,
          ),
        );
      }
      for (final (:page, :fragment) in content[cell.bounds]!) {
        (pages[page] ??= []).add(fragment);
      }
    }
    originalEnd = end;
    updatedEnd = end + shift;
    if (repeat && end >= header.bodyEnd && space.repeatThrough == null) {
      space.repeatThrough = pageOf(updatedEnd - 2 * _epsilon);
    }
    // 保留当前页供下一行接着排，已放满的页立即交给增量分页器。
    final lastPage = pageOf(updatedEnd - 2 * _epsilon);
    while (nextPage < lastPage) {
      yield finish(nextPage, pageEnd(nextPage), last: false);
      nextPage++;
    }
  }
  final end = updatedEnd + blocks.first.bodyBottom;
  final lastPage = pageOf(end - 2 * _epsilon);
  while (nextPage <= lastPage) {
    yield finish(
      nextPage,
      math.min(end, pageEnd(nextPage)),
      last: nextPage == lastPage,
    );
    nextPage++;
  }
}
