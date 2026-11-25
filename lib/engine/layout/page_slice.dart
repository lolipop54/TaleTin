part of 'chapter_paginator.dart';

/// 页内一个片段：某个块在该页上的连续若干行（或整块图片/分隔线）。
class PageFragment {
  const PageFragment({
    required this.block,
    required this.lineFrom,
    required this.lineTo,
    required this.y,
    required this.height,
    this.tableFrame,
    this.tableGridFrame,
    this.tablePageBorders,
    this.frameOnly = false,
    this.tableTopEdge = true,
    this.tableBottomEdge = true,
    this.omitSharedTop = false,
    this.clipSharedBottom = false,
    this.repeatedTableFrame = false,
  });

  /// 整块放入（图片、分隔线、标题）：
  /// 文本块的行范围就是它的全部行，图片与分隔线没有行。
  PageFragment.whole(MeasuredBlock block, {required double y})
    : this(
        block: block,
        lineFrom: 0,
        lineTo: block.lines.length,
        y: y,
        height: block.height,
      );

  factory PageFragment.containerTail(
    MeasuredBlock anchor,
    ContainerFlowTail tail,
    double y,
    double extent,
  ) {
    // 接着画上一片已占用的父框底部，只把新增的留白推进到正文流。
    final overlap = tail.frames.fold(
      0.0,
      (value, frame) => math.max(value, frame.last ? frame.bottom : 0),
    );
    return PageFragment(
      block: MeasuredBlock(
        blockId: anchor.blockId,
        kind: anchor.kind,
        isDecoration: true,
        containerBoxes: tail.frames,
        height: extent + overlap,
      ),
      lineFrom: 0,
      lineTo: 0,
      y: y - overlap,
      height: extent + overlap,
      frameOnly: true,
    );
  }

  final MeasuredBlock block;

  /// 行范围 [lineFrom, lineTo)；整块放入时两者都是 0
  final int lineFrom;
  final int lineTo;

  /// 页内顶部偏移
  final double y;

  /// 本片段占用的高度
  final double height;
  final Rect? tableFrame;

  /// 跨行格自身的片段与实际画边线的网格可能不同高。后者沿相邻行的物理断点投影。
  final Rect? tableGridFrame;
  final List<TableVerticalBorder>? tablePageBorders;
  Rect? get paintedTableFrame => tableGridFrame ?? tableFrame;
  final bool frameOnly;
  final bool tableTopEdge, tableBottomEdge;
  final bool omitSharedTop, clipSharedBottom;

  /// 原网格已经合并过边线。续页表头与当前正文在纸面接触，分两次画接缝。
  final bool repeatedTableFrame;

  PageFragment withGridBreak({
    required bool omitTop,
    required bool clipBottom,
  }) => PageFragment(
    block: block,
    lineFrom: lineFrom,
    lineTo: lineTo,
    y: y,
    height: height,
    frameOnly: frameOnly,
    tableFrame: tableFrame,
    tableGridFrame: tableGridFrame,
    tablePageBorders: tablePageBorders,
    tableTopEdge: tableTopEdge,
    tableBottomEdge: tableBottomEdge,
    omitSharedTop: omitTop,
    clipSharedBottom: clipBottom,
    repeatedTableFrame: repeatedTableFrame,
  );

  Size? get imageSize => block.imageSize;

  /// 显示行可能以阅读器补的两个缩进字符开头，书签只记录原文偏移。
  int get sourceStart => block.lines.isEmpty
      ? 0
      : math.max(0, block.lines[lineFrom].start - block.displayPrefixLength);

  /// 行首属于新行。段末位置也能回到最后一个片段。
  bool containsSourceOffset(int offset) {
    if (block.lines.isEmpty) return true;
    final end = block.lines[lineTo - 1].end - block.displayPrefixLength;
    return offset >= sourceStart &&
        (offset < end || (lineTo == block.lines.length && offset == end));
  }

  /// 页内图片的真实位置；横屏按高度缩小时仍位于容器中央。
  Rect? imageRectIn(double availableWidth) =>
      frameOnly ? null : block.imageRectIn(availableWidth, top: y);

  /// 页内一点落在哪张行内图片上；没有命中时返回 null。
  ///
  /// 坐标与绘制一致：片段顶部 + 行高 + 图片在行内的偏移。
  Iterable<({InlineImagePlacement image, Rect rect})>
  get positionedInlineImages sync* {
    if (frameOnly || block.lines.isEmpty) return;
    final width = block.layoutWidth;
    if (width == null) return;
    var top = y + block.textTopOf(lineFrom);
    for (var line = lineFrom; line < lineTo; line++) {
      final left = block.inset + block.horizontalOffset(line, width);
      for (final image in block.inlineImagesInLines(line, line + 1)) {
        yield (
          image: image,
          rect: Offset(left + image.left, top + image.top) & image.size,
        );
      }
      top += block.lines[line].height;
    }
  }

  InlineImagePlacement? inlineImageAt(Offset point) => positionedInlineImages
      .where((p) => p.rect.contains(point))
      .firstOrNull
      ?.image;

  /// 是否为跨页片段的后续部分（首行缩进只出现在 lineFrom == 0 的那一片）
  bool get isContinuation => block.lines.isNotEmpty && lineFrom > 0;

  @override
  String toString() =>
      'Fragment(${block.blockId}[$lineFrom,$lineTo)@$y,${height.toStringAsFixed(1)})';
}

/// 页首/页尾锚点：还没有摘录，摘录由上层（章节排版服务）补齐。
class PageAnchor {
  const PageAnchor({
    required this.blockId,
    required this.utf16Offset,
    this.affinity = LocatorAffinity.center,
  });

  final String blockId;
  final int utf16Offset;
  final LocatorAffinity affinity;
}

/// 一页的排版结果（不含章节信息，章节信息由上层附上）。
class PageSlice {
  const PageSlice({
    required this.index,
    required this.fragments,
    List<PageFragment>? paintFragments,
    this.backgroundAreas = const {},
    required this.usedHeight,
    required this.start,
    required this.end,
  }) : paintFragments = paintFragments ?? fragments;

  /// 章内页序，从 0 开始
  final int index;

  /// 原文片段供位置、选文和朗读使用。绘制另包含续页的表头副本。
  final List<PageFragment> fragments;
  final List<PageFragment> paintFragments;

  /// 分页时跨页背景图的定位框，坐标相对于本页。
  final Map<int, Rect> backgroundAreas;
  final double usedHeight;

  PageSlice withBackgroundAreas(Map<int, Rect> areas) => PageSlice(
    index: index,
    fragments: fragments,
    paintFragments: paintFragments,
    usedHeight: usedHeight,
    start: start,
    end: end,
    backgroundAreas: Map.unmodifiable(areas),
  );

  /// 普通图片按来源顺序绘制，定位图片叠在普通内容上。定位仍用原片段。
  Iterable<PageFragment> get paintedImages =>
      imagesInPaintOrder(paintFragments);

  /// 页首表格的占位片段可以带图片尺寸，但不绘制图片。
  bool get hasPaperArtwork {
    for (final fragment in fragments) {
      if (fragment.frameOnly || fragment.block.isDecoration) continue;
      return fragment.block.paperArtwork && fragment.imageSize != null;
    }
    return false;
  }

  /// 本页第一个字符与最后一个字符的位置
  final PageAnchor start;
  final PageAnchor end;
}

Iterable<PageFragment> imagesInPaintOrder(List<PageFragment> fragments) sync* {
  for (final overlay in [false, true]) {
    for (final f in fragments) {
      if (!f.frameOnly &&
          f.imageSize != null &&
          (f.block.positionedOverlay || f.block.isPageImage) == overlay) {
        yield f;
      }
    }
  }
}
