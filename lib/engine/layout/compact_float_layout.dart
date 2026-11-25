part of 'parallel_flow_layout.dart';

typedef _ColumnContent = (List<MeasuredBlock>, List<double>, double);
typedef _PlacedColumn = ({
  Rect bounds,
  _ColumnContent content,
  double scale,
  double? keepHeight,
});

/// 续排时正文仍绕开整个图框，只有分页器需要知道本页必须保留到哪一行。
class FloatPageFit {
  const FloatPageFit(this.blocks, [this._captionStarts = const {}]);
  final List<MeasuredBlock> blocks;
  final Map<String, double> _captionStarts;
  bool get hasContinuableCaption => _captionStarts.isNotEmpty;

  double get leadingImageBottom {
    final overlappingPair =
        blocks.length == 2 &&
        blocks.every((b) => b.imageSize != null) &&
        blocks.first.tableBounds!.overlaps(blocks.last.tableBounds!);
    var bottom = 0.0;
    for (final b in blocks) {
      if (b.imageSize != null &&
          !b.positionedOverlay &&
          (overlappingPair || b.tableBounds!.top < .1)) {
        bottom = math.max(
          bottom,
          _captionStarts[b.blockId] ?? b.tableBounds!.bottom,
        );
      }
    }
    return bottom;
  }
}

extension CompactFloatLayout on ParallelFlowLayout {
  _ColumnContent _measureColumn(
    DisplayElement e,
    BlockMeasurer measurer,
    double contentWidth,
    double scale,
  ) {
    final intrinsicColumn =
        e.tag != 'img' &&
        styles[e.styleId ?? 0].size.width?.isAuto != false &&
        e.firstBlock == e.lastBlock &&
        content.blocks[e.firstBlock!].kind == BlockKind.image;
    final columnMeasurer = scale == 1 && !intrinsicColumn
        ? measurer
        : measurer.withOptions(
            options,
            floatContentWidth: (elementId: e.id, width: contentWidth),
          );
    final blocks = <MeasuredBlock>[];
    var height = 0.0;
    MeasuredBlock? previous;
    final tops = <double>[];
    for (var b = e.firstBlock!; b <= e.lastBlock!; b++) {
      final source = content.blocks[b];
      var measured = _measure(columnMeasurer, source);
      if (columnMeasurer != measurer && measured.imageSize != null) {
        // 百分比宽图、固定像素图都以原来显示的宽高为基数，避免重复缩放。
        final size = _measure(measurer, source).imageSize! * scale;
        measured = measured.withBoxEdges(
          first: measured.boxFirst,
          last: measured.boxLast,
          height: measured.height - measured.imageSize!.height + size.height,
          imageSize: size,
        );
      }
      if (previous != null) height += measurer.gapBefore(previous, measured);
      tops.add(height);
      blocks.add(measured);
      height += measured.height;
      previous = measured;
    }
    return (blocks, tops, height);
  }

  /// 先按原尺寸靠左或靠右摆放。仅在页尾考虑缩图；试排图注期间不重复量旁边的长段落。
  _PlacedColumn _placeColumn(
    DisplayElement element,
    BlockMeasurer measurer,
    List<FloatFootprint> placed, {
    required double parentWidth,
    required double width,
    required double horizontalSpace,
    required double verticalSpace,
    required double topInset,
    required bool rightSide,
    required double startY,
    required double? firstTop,
  }) {
    final normal = _measureColumn(element, measurer, width, 1);
    double outer(double scale) =>
        math.min(parentWidth, width * scale + horizontalSpace);
    _PlacedColumn at(
      LineInterval band,
      double y,
      _ColumnContent content,
      double scale, [
      double? keepHeight,
    ]) {
      final w = outer(scale);
      final x = rightSide ? band.right - w : band.left;
      return (
        bounds: Rect.fromLTWH(x, y, w, content.$3 + verticalSpace),
        content: content,
        scale: scale,
        keepHeight: keepHeight,
      );
    }

    var y = startY;
    var band = floatLineInterval(placed, parentWidth, y);
    while (band.right - band.left < outer(1) - .001) {
      y = band.nextBottom;
      band = floatLineInterval(placed, parentWidth, y);
    }
    final natural = at(band, y, normal, 1);
    if (firstTop == null || width <= 0) return natural;
    final pageHeight = options.contentHeight;
    int pageAt(double top) =>
        math.max(0, ((firstTop + top + .001) / pageHeight).floor());
    double roomAt(double top) =>
        (pageAt(top) + 1) * pageHeight - firstTop - top;
    final firstPage = pageAt(startY), naturalPage = pageAt(y);
    final fitsNaturally = normal.$3 + verticalSpace <= roomAt(y) + .000001;
    if (naturalPage == firstPage && fitsNaturally) return natural;

    var imageHeight = 0.0;
    for (final block in normal.$1) {
      if (block.imageSize == null) continue;
      if (!canCompactIllustration(block, tree)) return natural;
      imageHeight += block.imageSize!.height;
    }
    if (imageHeight == 0) return natural;

    // 先争取同页放下整张图与完整图注。整组失败后才试图注续行。
    double needed(_ColumnContent c, int? description) {
      if (description == null) return c.$3 + verticalSpace;
      final text = c.$1[description];
      if (text.lines.length == 1 && description == c.$1.length - 1) {
        return c.$3 + verticalSpace;
      }
      return topInset +
          c.$2[description] +
          text.bodyTop +
          text.lines.first.height +
          (text.lines.length == 1 ? text.bodyBottom : 0);
    }

    _PlacedColumn? fit(int? description, _PlacedColumn? best) {
      // 前面已有浮图时，缩窄还可能让两图并排。按可用行宽逐次试到原来所在的行，
      // 优先更早的纸面，同一纸面选显示尺寸最大的结果。
      var row = startY;
      while (row <= y) {
        final rowBand = floatLineInterval(placed, parentWidth, row);
        final available = roomAt(row);
        final rowWidth = rowBand.right - rowBand.left;
        var scale = math.min(
          1.0 -
              math.max(0.0, needed(normal, description) - available) /
                  imageHeight,
          rowWidth >= outer(1) - .001
              ? 1.0
              : (rowWidth - horizontalSpace) / width,
        );
        while (scale + 1e-9 >= minimumCompactImageScale &&
            (best == null ||
                pageAt(row) < pageAt(best.bounds.top) ||
                (pageAt(row) == pageAt(best.bounds.top) &&
                    scale > best.scale + 1e-9))) {
          scale = math.max(minimumCompactImageScale, scale);
          final trial = scale == 1
              ? normal
              : _measureColumn(element, measurer, width * scale, scale);
          final required = needed(trial, description);
          final excess = required - available;
          if (excess <= .000001) {
            best = at(
              rowBand,
              row,
              trial,
              scale,
              description == null ? null : required,
            );
            break;
          }
          // 图注变窄可能多占一行。只再扣实测还差的高度，图注字号与边距照旧。
          if (scale <= minimumCompactImageScale) break;
          scale -= excess / imageHeight;
        }
        if (row >= y) break;
        row = rowBand.nextBottom;
      }
      return best;
    }

    final whole = fit(null, fitsNaturally ? natural : null);
    if (whole != null && pageAt(whole.bounds.top) == firstPage) return whole;
    final description = _descriptionStart(element, normal.$1);
    if (description != null) {
      final split = fit(description, null);
      if (split != null &&
          (whole == null ||
              pageAt(split.bounds.top) < pageAt(whole.bounds.top))) {
        return split;
      }
      // 即使整段图注比一整页还高，页尾连首行都放不下时也要先换页。
      if (whole == null) {
        return at(band, y, normal, 1, needed(normal, description));
      }
    }
    return whole ?? natural;
  }

  /// 单图浮框内，一段题注从首行保留；有独立图名时先保留完整图名。
  int? _descriptionStart(DisplayElement element, List<MeasuredBlock> blocks) {
    if (blocks.length < 2 || blocks.first.imageSize == null) return null;
    for (var i = 1; i < blocks.length; i++) {
      final b = blocks[i];
      if (!b.isText ||
          !(b.kind == BlockKind.paragraph ||
              b.kind == BlockKind.caption ||
              (i == 1 && blocks.length > 2 && b.kind == BlockKind.heading))) {
        return null;
      }
    }
    final i = blocks.length == 2 ? 1 : 2;
    final index = element.firstBlock! + i;
    final avoid = tree
        .chainOf(index)
        .any(
          (c) =>
              styles[c.styleId].block.breakInside?.startsWith('avoid') == true,
        );
    if (avoid ||
        styles[content.blocks[index].styleId ?? 0].block.breakInside
                ?.startsWith('avoid') ==
            true) {
      return null;
    }
    return i;
  }

  FloatPageFit fitForPage(
    List<MeasuredBlock> original,
    BlockMeasurer measurer,
    double firstTop,
  ) {
    final pageHeight = options.contentHeight;
    // 绝大多数页上的浮图本来就能放下，直接沿用已经量好的绕排行。
    if (!original.any(
      (b) =>
          b.imageSize != null &&
          !b.positionedOverlay &&
          firstTop + b.tableBounds!.bottom > pageHeight + .000001,
    )) {
      return FloatPageFit(original);
    }
    final start = tree.blockIndexById[original.first.blockId];
    final elements = groups[start];
    if (start == null ||
        elements == null ||
        _side(elements.first) == null ||
        _overlappingImages.contains(start) ||
        _relativeImages.containsKey(start)) {
      return FloatPageFit(original);
    }
    final captionStarts = <String, double>{};
    final blocks = _measureGroup(
      start,
      measurer,
      firstTop: firstTop,
      original: original,
      captionStarts: captionStarts,
    );
    return FloatPageFit(blocks, captionStarts);
  }
}
