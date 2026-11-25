part of 'chapter_paginator.dart';

/// 显示框与本次页/滚动片段的交集。块内框按行范围裁剪；父层的上下
/// 留白只在真实首尾扣除，中间续页不能重复加顶边或减底边。
(Rect, ContainerBoxFrame, bool, bool)? containerBackgroundPart(
  PageFragment fragment,
  ContainerBoxFrame frame,
) {
  final block = fragment.block;
  var top = fragment.y, bottom = fragment.y + fragment.height;
  var first = frame.first, last = frame.last;
  if (block.lines.isNotEmpty) {
    final start = math.max(fragment.lineFrom, frame.lineFrom);
    final end = math.min(fragment.lineTo, frame.lineTo ?? block.lines.length);
    if (end <= start) return null;
    if (start > fragment.lineFrom) {
      top += block.textTopOf(fragment.lineFrom);
      for (var i = fragment.lineFrom; i < start; i++) {
        top += block.lines[i].height;
      }
    }
    if (end < fragment.lineTo) {
      bottom = fragment.y + block.textTopOf(fragment.lineFrom);
      for (var i = fragment.lineFrom; i < end; i++) {
        bottom += block.lines[i].height;
      }
    }
    first = first && start == frame.lineFrom;
    last = last && end == (frame.lineTo ?? block.lines.length);
  }
  if (first) top += frame.top;
  if (frame.height != null) {
    bottom = math.min(bottom, top + frame.height!);
  } else if (last) {
    bottom -= frame.bottom;
  }
  if (bottom <= top) return null;
  return (
    Rect.fromLTWH(frame.left, top, frame.width, bottom - top),
    frame,
    first,
    last,
  );
}

/// 旧式块编号与 DOM 元素编号都从非负整数开始。负键单独标识块本身的背景。
int blockBackgroundKey(int boxId) => ~boxId;

Iterable<ContainerBoxFrame> backgroundFrames(
  MeasuredBlock block, {
  bool includePlainBox = false,
}) {
  final box = block.box, id = block.boxId, width = block.layoutWidth;
  if (id == null ||
      box == null ||
      width == null ||
      block.imageSize != null ||
      (!includePlainBox &&
          box.backgroundImage == null &&
          !block.hasClonedBox)) {
    return block.containerBoxes;
  }
  return [
    ...block.containerBoxes,
    ContainerBoxFrame(
      elementId: blockBackgroundKey(id),
      box: box,
      first: block.boxFirst,
      last: block.boxLast,
      left: block.inset - box.insetLeft - block.boxIndent,
      width:
          width +
          box.insetLeft +
          box.insetRight +
          block.boxIndent +
          (block.codeBox?.insetRight ?? 0),
      top: block.bodyTop - box.insetTop,
      bottom: block.bodyBottom - box.insetBottom,
    ),
  ];
}

/// 只补在断点被切开的那几层。真正的首尾已经在测量时计入正文高度。
double _cloneInsets(MeasuredBlock block, int line, {required bool top}) {
  var result = 0.0;
  for (final f in block.containerBoxes) {
    final end = f.lineTo ?? block.lines.length;
    if (!f.box.cloneDecoration ||
        line < f.lineFrom ||
        (block.lines.isNotEmpty && line >= end)) {
      continue;
    }
    if (top && (!f.first || line > f.lineFrom)) result += f.box.insetTop;
    if (!top && (!f.last || line + 1 < end)) result += f.box.insetBottom;
  }
  final own = block.box;
  if (own != null && own.cloneDecoration && block.imageSize == null) {
    if (top && (!block.boxFirst || line > 0)) result += own.insetTop;
    if (!top && (!block.boxLast || line + 1 < block.lines.length)) {
      result += own.insetBottom;
    }
  }
  return result;
}

class ContainerPageGeometry {
  const ContainerPageGeometry(
    this.rect,
    this.box,
    this.first,
    this.last,
    this.paged,
  );
  final Rect rect;
  final BlockBox box;
  final bool first, last, paged;
  bool get topEdge => first || (paged && box.cloneDecoration);
  bool get bottomEdge => last || (paged && box.cloneDecoration);
}

/// 把同一 DOM 元素在本页上的块或行范围接起来。内层续框只到外层内容区。
Map<int, ContainerPageGeometry> containerPageGeometry(
  List<PageFragment> fragments,
  double? pageHeight, {
  bool imagesOnly = false,
  bool includePlainBox = false,
}) {
  final result = <int, ContainerPageGeometry>{};
  for (final fragment in fragments) {
    final block = fragment.block;
    if (block.tableId != null && !block.isTableBox && !block.isParallelFlow) {
      continue;
    }
    var outerTop = 0.0, outerBottom = 0.0;
    for (final f in backgroundFrames(block, includePlainBox: includePlainBox)) {
      if (imagesOnly &&
          f.box.backgroundImage == null &&
          !f.box.cloneDecoration) {
        continue;
      }
      final part = containerBackgroundPart(fragment, f);
      if (part == null) continue;
      final (rect, _, first, last) = part;
      if (!imagesOnly || f.box.backgroundImage != null) {
        final previous = result[f.elementId];
        final top =
            previous?.rect.top ??
            (pageHeight != null && !first ? outerTop : rect.top);
        final bottom = pageHeight != null && !last
            ? math.max(rect.bottom, pageHeight - outerBottom)
            : rect.bottom;
        if (bottom > top) {
          result[f.elementId] = ContainerPageGeometry(
            Rect.fromLTRB(rect.left, top, rect.right, bottom),
            f.box,
            previous?.first ?? first,
            last,
            pageHeight != null,
          );
        }
      }
      if (f.box.cloneDecoration) {
        if (!first) outerTop += f.box.insetTop;
        if (!last) outerBottom += f.box.insetBottom;
      }
    }
  }
  return result;
}

bool _continuesBackground(PageSlice page, double height) {
  if (!_hasContainerImage(page)) return false;
  return containerPageGeometry(
    page.fragments,
    height,
    imagesOnly: true,
  ).values.any((piece) => !piece.last && !piece.box.cloneDecoration);
}

bool _hasContainerImage(PageSlice page) => page.fragments.any(
  (fragment) =>
      fragment.block.box?.backgroundImage != null ||
      fragment.block.containerBoxes.any(
        (frame) => frame.box.backgroundImage != null,
      ),
);

class _BackgroundExtent {
  _BackgroundExtent(this.needsEnd);
  final bool needsEnd;
  double height = 0;
  bool complete = false;
}

typedef _BackgroundPart = ({
  ContainerPageGeometry piece,
  double before,
  _BackgroundExtent extent,
});

Rect _backgroundRect(_BackgroundPart part) {
  final rect = part.piece.rect;
  // 如同先画完整的 border-box，再切出本页。绘制器只从完整框扣一次边框。
  final top = rect.top - part.before;
  return Rect.fromLTWH(rect.left, top, rect.width, part.extent.height);
}

Iterable<PageSlice?> _positionBoxBackgrounds(
  Iterable<PageSlice?> pages,
  double height,
) sync* {
  final extents = <int, _BackgroundExtent>{};
  final pending = Queue<(PageSlice, Map<int, _BackgroundPart>)>();
  Iterable<PageSlice> deliver({bool atEnd = false}) sync* {
    while (pending.isNotEmpty) {
      final (page, parts) = pending.first;
      if (!atEnd &&
          parts.values.any((p) => p.extent.needsEnd && !p.extent.complete)) {
        break;
      }
      pending.removeFirst();
      yield parts.isEmpty
          ? page
          : page.withBackgroundAreas({
              for (final entry in parts.entries)
                entry.key: _backgroundRect(entry.value),
            });
    }
  }

  for (final page in pages) {
    if (page == null || (pending.isEmpty && !_hasContainerImage(page))) {
      yield page;
      continue;
    }
    final parts = <int, _BackgroundPart>{};
    for (final entry in containerPageGeometry(
      page.fragments,
      height,
      imagesOnly: true,
    ).entries) {
      final id = entry.key, piece = entry.value;
      if (piece.box.cloneDecoration ||
          (piece.first && piece.last && !extents.containsKey(id))) {
        continue;
      }
      final extent = extents.putIfAbsent(
        id,
        () => _BackgroundExtent(piece.box.backgroundImage!.needsFullHeight),
      );
      parts[id] = (piece: piece, before: extent.height, extent: extent);
      extent.height += piece.rect.height;
      if (piece.last) {
        extents.remove(id);
        extent.complete = true;
      }
    }
    pending.add((page, parts));
    yield* deliver();
    if (pending.isNotEmpty) yield null;
  }
  yield* deliver(atEnd: true);
}
