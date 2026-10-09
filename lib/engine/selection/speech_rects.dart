import 'dart:math' as math;

import 'package:flutter/painting.dart';

import '../../domain/models/book_document.dart';
import '../../domain/models/locator.dart';
import '../layout/chapter_layout.dart';

/// 听书范围使用与 PageCanvas 相同的片段分组、字距及断行回退。
/// 返回内容盒坐标；不修改选区，也不参与分页。
List<Rect> speechRectsForPage({
  required ChapterLayout layout,
  required int pageIndex,
  required Locator from,
  required Locator to,
}) {
  if (from.bookId != layout.bookId ||
      to.bookId != layout.bookId ||
      from.contentVersion != layout.contentVersion ||
      to.contentVersion != layout.contentVersion ||
      from.chapterId != layout.chapterId ||
      to.chapterId != layout.chapterId) {
    return const [];
  }
  final first = layout.blocks.indexWhere((b) => b.blockId == from.blockId);
  final last = layout.blocks.indexWhere((b) => b.blockId == to.blockId);
  final page = layout.page(pageIndex);
  if (first < 0 || last < first || page == null) return const [];
  final rects = <Rect>[];
  for (final fragment in page.fragments) {
    if (fragment.frameOnly) continue;
    final block = fragment.block;
    final order = layout.blocks.indexOf(block);
    if (block.isDecoration || order < first || order > last) continue;
    final start = order == first
        ? from.utf16Offset + block.displayPrefixLength
        : block.displayPrefixLength;
    final end = order == last
        ? to.utf16Offset + block.displayPrefixLength
        : block.text.length;
    final width = (block.layoutWidth ?? layout.options.contentWidthFor(block.kind));
    final justify = block.tableId == null && switch (block.kind) {
      BlockKind.paragraph || BlockKind.listItem || BlockKind.footnote => true,
      _ => false,
    };
    double spacing(int i) =>
        block.justifySpacingFor(i, maxWidth: width, enabled: justify,
          textScaler: layout.options.textScaler);
    var top = fragment.y;
    var index = fragment.lineFrom;
    void collect(TextPainter painter, int a, int b, double y) {
      final lo = math.max(start, a);
      final hi = math.min(end, b);
      if (hi <= lo) return;
      for (final box in painter.getBoxesForSelection(
        TextSelection(baseOffset: lo - a, extentOffset: hi - a),
      )) {
        final rect = box
            .toRect()
            .shift(Offset(block.inset, y))
            .intersect(Offset.zero & layout.contentSize);
        if (!rect.isEmpty) rects.add(rect);
      }
    }

    while (index < fragment.lineTo) {
      final gap = spacing(index);
      var stop = index + 1;
      if (gap <= 0 && !block.lines[index].hyphenated) {
        while (stop < fragment.lineTo && !block.lines[stop].hyphenated && spacing(stop) <= 0) {
          stop++;
        }
      }
      final painter = block.createFragmentPainter(
        lineFrom: index,
        lineTo: stop,
        textScaler: layout.options.textScaler,
        maxWidth: width,
        letterSpacing: gap,
      );
      if (painter.computeLineMetrics().length == stop - index) {
        collect(
          painter,
          block.lines[index].start,
          block.lines[stop - 1].end,
          top,
        );
        for (var i = index; i < stop; i++) {
          top += block.lines[i].height;
        }
      } else {
        // 正文重排多折一行时，同样按无限宽单行绘制计算，避免高亮错位。
        for (var i = index; i < stop; i++) {
          final single = block.createSingleLinePainter(
            lineIndex: i,
            textScaler: layout.options.textScaler,
            letterSpacing: spacing(i),
          );
          collect(single, block.lines[i].start, block.lines[i].end, top);
          single.dispose();
          top += block.lines[i].height;
        }
      }
      painter.dispose();
      index = stop;
    }
  }
  return rects;
}
