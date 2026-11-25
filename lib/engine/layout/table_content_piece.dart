part of 'table_layout.dart';

/// 连续网格中的一个完整字行或图片。换页只改变其显示纵坐标，
/// 分页、滚动和 Locator 都沿用同一段原文行号。
class TableContentPiece {
  const TableContentPiece(this.block, this.line, this.top, this.height);

  final MeasuredBlock block;
  final int? line;
  final double top, height;

  PageFragment at(double y) => PageFragment(
    block: block,
    lineFrom: line ?? 0,
    lineTo: line == null ? 0 : line! + 1,
    y: y,
    height: height,
  );
}

/// 多列的片段按单元格存放。取滚动位置时优先选穿过该高度且行首最近的一行，
/// 同一高度沿用原文顺序。落在格内留白时取后继行，表末取最后一行。
PageFragment? tableAnchorAt(List<PageFragment> fragments, double y) {
  PageFragment? hit, next, last;
  for (final f in fragments) {
    if (f.frameOnly || f.block.isDecoration) continue;
    if (f.y <= y && y < f.y + f.height) {
      if (hit == null || f.y > hit.y) hit = f;
    } else if (f.y > y && (next == null || f.y < next.y)) {
      next = f;
    }
    if (last == null || f.y >= last.y) last = f;
  }
  return hit ?? next ?? last;
}

Iterable<TableContentPiece> tableContentPieces(MeasuredBlock block) sync* {
  var y = block.tableTop;
  if (block.imageSize != null) {
    yield TableContentPiece(block, null, y, block.height);
    return;
  }
  for (var i = 0; i < block.lines.length; i++) {
    final height = block.lines[i].height;
    yield TableContentPiece(block, i, y, height);
    y += block.tableUnit > 0 ? block.tableUnit : height;
  }
}
