part of 'styled_table_pages.dart';

/// 跨行格按自身的连续高度分片。合并边线则沿实际排在本页的行绘制，
/// 下一行整体移页时，上一页未使用的页尾不应提前画出下一行的线色。
Iterable<(int, PageFragment)> _splitSpanFrames(
  MeasuredBlock block,
  List<TableBreakRow> rows,
  int firstRow,
  Map<double, double> shifts,
  Map<double, double> ends,
  double top,
  double bottom,
  TablePageSpace space,
) sync* {
  final bounds = block.tableBounds!;
  final pageOf = space.pageOf;
  final extents = <int, Rect>{};
  for (
    var r = firstRow;
    r < rows.length && rows[r].top < bounds.bottom - _epsilon;
    r++
  ) {
    final row = rows[r];
    final start = row.top + shifts[row.top]!, end = ends[row.bottom]!;
    for (var p = pageOf(start); p <= pageOf(end - 2 * _epsilon); p++) {
      final rect = Rect.fromLTRB(
        bounds.left,
        space.local(math.max(start, space.top(p)), p),
        bounds.right,
        space.local(math.min(end, space.end(p)), p),
      );
      extents[p] = extents[p]?.expandToInclude(rect) ?? rect;
    }
  }
  final edges = <int, List<TableVerticalBorder>>{};
  for (final edge in block.tableVerticalBorders) {
    final start = edge.top + shifts[edge.top]!, end = ends[edge.bottom]!;
    for (var p = pageOf(start); p <= pageOf(end - 2 * _epsilon); p++) {
      final grid = extents[p];
      if (grid == null) continue;
      final a = math.max(grid.top, space.local(start, p)),
          b = math.min(grid.bottom, space.local(end, p));
      if (b > a) {
        (edges[p] ??= []).add((
          top: a,
          bottom: b,
          border: edge.border,
          left: edge.left,
        ));
      }
    }
  }
  for (final MapEntry(key: p, value: grid) in extents.entries) {
    final a = space.local(math.max(top, space.top(p)), p),
        b = space.local(math.min(bottom, space.end(p)), p);
    yield (
      p,
      PageFragment(
        block: block,
        lineFrom: 0,
        lineTo: 0,
        y: grid.top,
        height: grid.height,
        frameOnly: true,
        tableFrame: b > a
            ? Rect.fromLTRB(bounds.left, a, bounds.right, b)
            : null,
        tableGridFrame: grid,
        tablePageBorders: edges[p] ?? const [],
        tableTopEdge: p == extents.keys.first,
        tableBottomEdge: p == extents.keys.last,
      ),
    );
  }
}
