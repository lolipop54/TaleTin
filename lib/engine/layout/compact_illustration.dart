part of 'chapter_paginator.dart';

MeasuredBlock _fitImageOnPage(MeasuredBlock block, double available) {
  final size = block.imageSize!;
  final shortfall = block.height - available;
  if (shortfall <= ChapterPaginator._epsilon) return block;
  final remaining = size.height - shortfall;
  final minimum = size.height * minimumCompactImageScale;
  if (remaining + 1e-9 < minimum) return block;
  // 即使边界存在浮点误差，最终显示高度也不能低于原来的 60%。
  final height = math.max(minimum, remaining);
  return block.withBoxEdges(
    first: block.boxFirst,
    last: block.boxLast,
    height: block.height - size.height + height,
    imageSize: size * (height / size.height),
  );
}

extension _CompactIllustrations on ChapterPaginator {
  int _nextFlowIndex(MeasuredBlockSource blocks, int current) {
    var next = current + 1;
    while (blocks.has(next) &&
        (blocks[next].isPageImage || blocks[next].collapsesThrough)) {
      next++;
    }
    return next;
  }

  bool _breaksBefore(MeasuredBlock block) =>
      chapterStarts.contains(block.blockId) ||
      measurer?.displayTree?.pageBreaks[block.blockId]?.contains(0) == true;

  bool _canCompactImage(MeasuredBlockSource blocks, int index) {
    final image = blocks[index];
    return compactIllustrations &&
        image.tableId == null &&
        canCompactIllustration(image, measurer?.displayTree);
  }

  /// 图片下沿还要放下的图注。图注超长时沿用原分页的首行保留规则。
  double _imageTail(MeasuredBlockSource blocks, int i, double after) {
    final image = blocks[i];
    final caption = measurer?.displayTree?.galleryCaptions[image.blockId];
    if (caption == null) return after;
    final index = _nextFlowIndex(blocks, i);
    if (!blocks.has(index)) return after;
    final next = blocks[index];
    if (next.blockId != caption.id ||
        !next.isText ||
        next.pageTop != null ||
        _breaksBefore(next)) {
      return after;
    }
    final gap = _gapBetween(blocks, index);
    final full = gap + next.height;
    final tail = image.height + full <= pageHeight + ChapterPaginator._epsilon
        ? full
        : gap + next.bodyTop + next.lines.first.height;
    return math.max(after, tail);
  }

  /// 连续标题与紧邻的图一起试排；后接正文则给开头两行留位。
  /// 新纸面也放不下整组时，优先让主、副标题同页。
  ({int last, double headings, double minimum})? _headingGroup(
    MeasuredBlockSource blocks,
    int start,
    double headingTop,
  ) {
    var height = 0.0;
    var last = start;
    var i = start;
    for (; blocks.has(i); i = _nextFlowIndex(blocks, i)) {
      final b = blocks[i];
      if (b.kind != BlockKind.heading) break;
      if (i > start && _breaksBefore(b)) break;
      if (!b.isText ||
          b.isDecoration ||
          b.tableId != null ||
          b.pageTop != null ||
          measurer?.displayTree?.pageBreaks[b.blockId]?.any((n) => n > 0) ==
              true) {
        return null;
      }
      height += (i == start ? 0 : _gapBetween(blocks, i)) + b.height;
      if (height > pageHeight) return null;
      last = i;
    }
    final headingsOnly = last > start
        ? (last: last, headings: height, minimum: height)
        : null;
    if (!blocks.has(i)) return headingsOnly;
    final next = blocks[i];
    final startOfNext = height + _gapBetween(blocks, i);
    // 防孤题也要看缩图后的实际高度，否则标题会提前带着本可放下的浮图换页。
    if (parallelFlow != null &&
        next.isParallelFlow &&
        next.imageSize != null &&
        !_breaksBefore(next) &&
        headingTop + startOfNext + next.tableBounds!.bottom > pageHeight) {
      final natural = <MeasuredBlock>[next];
      for (
        var j = i + 1;
        blocks.has(j) && blocks[j].tableId == next.tableId;
        j++
      ) {
        natural.add(blocks[j]);
      }
      final fitted = parallelFlow!.fitForPage(
        natural,
        measurer!,
        headingTop + startOfNext,
      );
      final firstPart = fitted.leadingImageBottom;
      final minimum = startOfNext + firstPart;
      if (firstPart > 0 &&
          (headingTop + minimum <= pageHeight + ChapterPaginator._epsilon ||
              (fitted.hasContinuableCaption && minimum <= pageHeight))) {
        return (last: last, headings: height, minimum: minimum);
      }
      if (fitted.hasContinuableCaption &&
          headingTop > 0 &&
          minimum > pageHeight) {
        final fresh = parallelFlow!.fitForPage(natural, measurer!, startOfNext);
        final keep = startOfNext + fresh.leadingImageBottom;
        if (keep <= pageHeight) {
          return (last: last, headings: height, minimum: keep);
        }
      }
    }
    if (next.pageTop != null ||
        next.tableId != null ||
        next.isDecoration ||
        next.paperArtwork) {
      return headingsOnly;
    }
    if (_breaksBefore(next)) return headingsOnly;
    final size = next.imageSize;
    if (size == null) {
      if (last == start || next.kind != BlockKind.paragraph || !next.isText) {
        return headingsOnly;
      }
      final first = startOfNext + next.bodyTop + next.lines.first.height;
      var keep = first;
      if (next.lines.length == 1) {
        keep += next.bodyBottom;
      } else {
        final second = next.lines[1];
        final breaks = measurer?.displayTree?.pageBreaks[next.blockId];
        if (breaks?.contains(second.start - next.displayPrefixLength) != true) {
          keep += second.height;
          if (next.lines.length == 2) keep += next.bodyBottom;
        }
      }
      return (
        last: last,
        headings: height,
        minimum: keep <= pageHeight ? keep : first,
      );
    }
    final reduction = _canCompactImage(blocks, i)
        ? size.height * (1 - minimumCompactImageScale)
        : 0.0;
    final tail = _imageTail(blocks, i, _cloneInsets(next, 0, top: false));
    final minimum = startOfNext + next.height - reduction + tail;
    return (last: last, headings: height, minimum: minimum);
  }
}
