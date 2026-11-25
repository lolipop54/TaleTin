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
    if (b.positionedOverlay) continue;
    var top = b.tableTop;
    if (b.lines.isEmpty) {
      bands.add(_Band(b, order, 0, 0, top, b.height));
    } else {
      for (var line = 0; line < b.lines.length; line++) {
        final height =
            b.lines[line].height +
            (line == 0 ? b.bodyTop : 0) +
            (line == b.lines.length - 1 ? b.bodyBottom : 0);
        bands.add(
          _Band(
            b,
            order,
            line,
            line + 1,
            top,
            height,
            b.lines[line].floatInterval,
          ),
        );
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
      // 绕图段落在图底恢复整宽。用每行的实际占栏范围判断，避免把旁栏
      // 正文换页时的空隙加到图注里。段内各行即使换侧也要按原顺序接排。
      if ((previous.order == band.order ||
              (previous.left < band.right - .1 &&
                  band.left < previous.right - .1)) &&
          previous.top + previous.height <= band.top + .1) {
        top = math.max(
          top,
          previous.placed +
              previous.height +
              math.max(0, band.top - previous.top - previous.height),
        );
      }
    }
    // 章首负边距可伸入页眉，仍属于第一页，不能把第二个字送去“下一页”。
    final page = math.max(0, ((top + .01) / pageHeight).floor());
    if (top + band.height > (page + 1) * pageHeight + .1 &&
        top > page * pageHeight + .1) {
      top = (page + 1) * pageHeight;
    }
    band.placed = top;
    placed.add(band);
  }
  // 装饰图贴在包含块所属的页上。跨页的部分随纸面裁剪，
  // 不单独换页，也不把同列的正文推到下一页。
  final lastPage = placed.fold<int>(
    0,
    (p, b) => math.max(p, ((b.placed + .01) / pageHeight).floor()),
  );
  for (final (index, b) in blocks.indexed) {
    if (!b.positionedOverlay) continue;
    final band = _Band(b, index, 0, 0, b.tableTop, b.height);
    band.placed = firstTop + b.tableTop;
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
    final page = ((band.placed + .01) / pageHeight).floor().clamp(0, lastPage);
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
  _Band(
    this.block,
    this.order,
    this.from,
    this.to,
    this.top,
    this.height, [
    ({double left, double right})? interval,
  ]) : left = interval?.left ?? block.tableBounds!.left,
       right = interval?.right ?? block.tableBounds!.right;
  final MeasuredBlock block;
  final int order, from, to;
  final double top, height, left, right;
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
      if (b.positionedOverlay ||
          (b.tableTop >= from - .1 && b.tableTop < to - .1)) {
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
