import 'dart:ui';

import '../styles/style_box_value.dart';
import 'measured_text_geometry.dart';

int hiddenTableBorders(BorderSpec? border) {
  final sides = [border?.top, border?.right, border?.bottom, border?.left];
  var mask = 0;
  for (var side = 0; side < 4; side++) {
    if (sides[side]?.style == BorderLineStyle.hidden) mask |= 1 << side;
  }
  return mask;
}

typedef CollapsedBorder = ({double width, int style, Color color, int side});
typedef TableHorizontalBorder = ({
  double left,
  double right,
  CollapsedBorder border,
  bool top,
});
typedef TableVerticalBorder = ({
  double top,
  double bottom,
  CollapsedBorder border,
  bool left,
});

enum TableBorderSource { table, columnGroup, column, rowGroup, row, cell }

typedef _Edge = ({
  int cell,
  double start,
  double end,
  CollapsedBorder border,
  TableBorderSource source,
});

/// 同一条边先比较宽度，再按 CSS 线型顺序打破平局。交点绘制也使用这个顺序。
int compareTableLine(CollapsedBorder x, CollapsedBorder y) {
  final width = x.width.compareTo(y.width);
  if (width != 0) return width;
  const ranks = [0, 7, 6, 5, 8, 2, 4, 1, 3];
  return x.style == y.style ? 0 : ranks[x.style].compareTo(ranks[y.style]);
}

/// 在行列编号上按端点分段，所以跨行格的一条长边能逐段使用不同邻格的边线。
class CollapsedTableBorders {
  CollapsedTableBorders({this.rtl = false});
  final bool rtl;
  final _lines = <({bool horizontal, double at}), List<_Edge>>{};

  void add(
    int cell,
    Rect rect,
    BlockBox? box,
    int hidden, {
    TableBorderSource source = TableBorderSource.cell,
  }) {
    final widths = [
      box?.borderTop ?? 0.0,
      box?.borderRight ?? 0.0,
      box?.borderBottom ?? 0.0,
      box?.borderLeft ?? 0.0,
    ];
    for (var side = 0; side < 4; side++) {
      final horizontal = side.isEven;
      final start = horizontal ? rect.left : rect.top,
          end = horizontal ? rect.right : rect.bottom;
      final suppressed = hidden & (1 << side) != 0;
      if (start >= end || (cell < 0 && !suppressed && widths[side] == 0)) {
        continue;
      }
      final at = [rect.top, rect.right, rect.bottom, rect.left][side];
      (_lines[(horizontal: horizontal, at: at)] ??= []).add((
        cell: cell,
        start: start,
        end: end,
        source: source,
        border: (
          width: widths[side],
          style: suppressed ? -1 : box?.borderStyles[side] ?? 1,
          color: box?.borderColors[side] ?? const Color(0x00000000),
          side: side,
        ),
      ));
    }
  }

  void resolve(
    void Function(
      bool horizontal,
      double at,
      double start,
      double end,
      CollapsedBorder border,
      List<({int cell, int side})> cells,
    )
    segment,
  ) {
    for (final entry in _lines.entries) {
      final starts = <double, List<_Edge>>{}, ends = <double, List<_Edge>>{};
      for (final edge in entry.value) {
        (starts[edge.start] ??= []).add(edge);
        (ends[edge.end] ??= []).add(edge);
      }
      final points = {...starts.keys, ...ends.keys}.toList()..sort();
      final active = <_Edge>{};
      for (var i = 0; i + 1 < points.length; i++) {
        final at = points[i];
        active.removeAll(ends[at] ?? const []);
        active.addAll(starts[at] ?? const []);
        if (active.isEmpty) continue;
        final winner = active
            .reduce((a, b) => _compare(a, b) >= 0 ? a : b)
            .border;
        if (winner.style < 0 || winner.width <= 0) continue;
        final cells = [
          for (final e in active)
            if (e.cell >= 0) (cell: e.cell, side: e.border.side),
        ];
        if (cells.isNotEmpty) {
          segment(
            entry.key.horizontal,
            entry.key.at,
            at,
            points[i + 1],
            winner,
            cells,
          );
        }
      }
    }
  }

  int _compare(_Edge a, _Edge b) {
    final x = a.border, y = b.border;
    if ((x.style == -1) != (y.style == -1)) return x.style == -1 ? 1 : -1;
    final line = compareTableLine(x, y);
    if (line != 0) return line;
    if (a.source != b.source) return a.source.index.compareTo(b.source.index);
    bool first(int side) => side == 2 || side == (rtl ? 3 : 1);
    return (first(x.side) ? 1 : 0) - (first(y.side) ? 1 : 0);
  }
}
