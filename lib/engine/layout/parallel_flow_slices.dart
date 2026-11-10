import 'dart:math' as math;

import 'chapter_paginator.dart';
import 'measured_block.dart';

/// 每列按自己的图片和文字行避开页底。将某行移到下一页时，仅顺延
/// 与它横向重叠的后文；另一列仍可使用当前页余下空间。
List<List<PageFragment>> parallelFlowPages(
  List<MeasuredBlock> blocks,
  double firstTop,
  double pageHeight,
) {
  final bands = <_Band>[];
  for (var order = 0; order < blocks.length; order++) {
    final b = blocks[order];
    var top = b.tableTop;
    if (b.lines.isEmpty) {
      bands.add(_Band(b, order, 0, 0, top, b.height));
    } else {
      for (var line = 0; line < b.lines.length; line++) {
        final height =
            b.lines[line].height +
            (line == 0 ? b.bodyTop : 0) +
            (line == b.lines.length - 1 ? b.bodyBottom : 0);
        bands.add(_Band(b, order, line, line + 1, top, height));
        top += height;
      }
    }
  }
  bands.sort((a, b) {
    final byTop = a.top.compareTo(b.top);
    return byTop == 0 ? a.order.compareTo(b.order) : byTop;
  });
  final placed = <_Band>[];
  for (final band in bands) {
    var top = firstTop + band.top;
    for (final previous in placed) {
      final a = previous.block.tableBounds!, b = band.block.tableBounds!;
      if (a.left < b.right - .1 &&
          b.left < a.right - .1 &&
          previous.top + previous.height <= band.top + .1) {
        top = math.max(
          top,
          previous.placed +
              previous.height +
              math.max(0, band.top - previous.top - previous.height),
        );
      }
    }
    final page = ((top + .01) / pageHeight).floor();
    if (top + band.height > (page + 1) * pageHeight + .1 &&
        top > page * pageHeight + .1) {
      top = (page + 1) * pageHeight;
    }
    band.placed = top;
    placed.add(band);
  }
  final pages = <List<PageFragment>>[];
  // 页内仍按正文块顺序保存，定位、选文和全文拼接不采用临时视觉排序。
  placed.sort(
    (a, b) => a.order == b.order
        ? a.from.compareTo(b.from)
        : a.order.compareTo(b.order),
  );
  for (final band in placed) {
    final page = ((band.placed + .01) / pageHeight).floor();
    while (pages.length <= page) {
      pages.add([]);
    }
    pages[page].add(
      PageFragment(
        block: band.block,
        lineFrom: band.from,
        lineTo: band.to,
        y: band.placed - page * pageHeight,
        height: band.height,
      ),
    );
  }
  return pages;
}

class _Band {
  _Band(this.block, this.order, this.from, this.to, this.top, this.height);
  final MeasuredBlock block;
  final int order, from, to;
  final double top, height;
  double placed = 0;
}

List<PageFragment> parallelFlowFragments(
  List<MeasuredBlock> blocks,
  double from,
  double to,
  double y,
) {
  final result = <PageFragment>[];
  for (final b in blocks) {
    if (b.lines.isEmpty) {
      if (b.tableTop >= from - .1 && b.tableTop < to - .1) {
        result.add(PageFragment.whole(b, y: b.tableTop - from + y));
      }
      continue;
    }
    var top = b.tableTop;
    for (var i = 0; i < b.lines.length; i++) {
      final height =
          b.lines[i].height +
          (i == 0 ? b.bodyTop : 0) +
          (i == b.lines.length - 1 ? b.bodyBottom : 0);
      if (top >= from - .1 && top < to - .1) {
        result.add(
          PageFragment(
            block: b,
            lineFrom: i,
            lineTo: i + 1,
            y: top - from + y,
            height: height,
          ),
        );
      }
      top += height;
    }
  }
  return result;
}
