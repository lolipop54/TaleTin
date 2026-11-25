part of 'table_layout.dart';

// HTML 默认让 tr、td 沿用行组的对齐，行组默认为 middle。
String _cellVerticalAlign(DisplayNode cell, StyleTable styles) {
  for (
    DisplayNode? node = cell;
    node != null && node.element.role != 'table';
    node = node.parent
  ) {
    final align = styles[node.element.styleId ?? 0].text.verticalAlign;
    if (align == null) continue;
    if (align case VerticalAlignKeyword(:final keyword)) {
      if (const {'top', 'middle', 'bottom'}.contains(keyword)) return keyword;
    }
    return 'baseline';
  }
  return 'middle';
}

/// 首个行盒的文字基线相对格内容顶端的位置。只有参与基线对齐的格才需要它。
double _cellBaseline(List<_CellItem> items, double height, TextScaler scaler) {
  for (final item in items) {
    final block = item.block;
    final line = block.lines.firstOrNull;
    if (line == null) continue;
    for (final segment in line.segments) {
      if (segment.baseline > 0) {
        return item.top +
            block.bodyTop +
            line.textTop +
            segment.top +
            segment.baseline;
      }
    }
    final painter = block.createSingleLinePainter(
      lineIndex: 0,
      textScaler: scaler,
    );
    final baseline = painter.computeDistanceToActualBaseline(
      TextBaseline.alphabetic,
    );
    painter.dispose();
    return item.top + block.bodyTop + line.textTop + baseline;
  }
  return height;
}

typedef _CellItem = ({
  MeasuredBlock block,
  double left,
  double width,
  double top,
});

// 格内的列表从格的内容边缘开始。外层表格边框和格的 padding 已经扣过，
// 这里仅加入列表自己的边距；一个列表的上下边距分别归首项和末项。
EdgeInsets _cellListEdges(
  DisplayTree tree,
  int index,
  StyleTable styles,
  LayoutOptions options,
  double width,
) {
  var left = 0.0, right = 0.0, before = 0.0, after = 0.0;
  var depth = 0;
  final chain = tree.source!.chainOfBlock(index);
  for (final e in chain.skip(
    chain.lastIndexWhere((e) => e.role == 'cell') + 1,
  )) {
    if (e.tag != 'ul' && e.tag != 'ol') continue;
    final style = styles[e.styleId ?? 0];
    final ctx = DisplayBoxLayout.context(
      style,
      options,
      width - left - right,
      authorTableCell: true,
    );
    final margin = style.block.margin, pad = style.box.padding;
    final defaultMargin = depth == 0 ? ctx.fontSize : 0.0;
    left += (pad?.left?.resolve(ctx) ?? 40) + (margin?.left?.resolve(ctx) ?? 0);
    right +=
        (pad?.right?.resolve(ctx) ?? 0) + (margin?.right?.resolve(ctx) ?? 0);
    if (e.firstBlock == index) {
      before += margin?.top?.resolve(ctx) ?? defaultMargin;
    }
    if (e.lastBlock == index) {
      after += margin?.bottom?.resolve(ctx) ?? defaultMargin;
    }
    depth++;
  }
  return EdgeInsets.fromLTRB(left, before, right, after);
}

class _TableRows {
  _TableRows(int count)
    : heights = List.filled(count, 0),
      baselines = List.filled(count, 0),
      _fixed = List.filled(count, false),
      _percent = List.filled(count, 0),
      _below = List.filled(count, 0);

  final List<double> heights, baselines, _percent, _below;
  final List<bool> _fixed;
  final _spans =
      <
        ({int row, int span, double height, double natural, double? baseline})
      >[];
  final _spanStarts = <int>{};

  void applyHeight(
    int row,
    SizeStyleSpec style,
    LengthContext context, {
    bool cell = false,
  }) {
    if (style.height case PercentLength(:final value)) {
      _percent[row] = math.max(_percent[row], value);
    } else if (style.height != null && !style.height!.isAuto) {
      _fixed[row] = true;
    }
    // 单元格的盒模型和实际文字高度已经由 measureCell 一起计算。
    if (!cell) {
      heights[row] = math.max(
        heights[row],
        BoxSizeResolver.heightOf(context, style, null).use(0),
      );
    }
  }

  void measureCell(
    ContentTableCell cell,
    double height,
    double natural,
    double? baseline,
  ) {
    final row = cell.row;
    if (baseline != null) baselines[row] = math.max(baselines[row], baseline);
    if (cell.rowSpan > 1) {
      _spanStarts.add(row);
      _spans.add((
        row: row,
        span: cell.rowSpan,
        height: height,
        natural: natural,
        baseline: baseline,
      ));
      return;
    }
    heights[row] = math.max(heights[row], height);
    if (baseline != null) {
      _below[row] = math.max(_below[row], natural - baseline);
    }
  }

  void distribute(double gap, double? gridHeight) {
    var remainingPercent = 1.0;
    for (var i = 0; i < heights.length; i++) {
      _percent[i] = math.min(remainingPercent, _percent[i]);
      remainingPercent -= _percent[i];
      heights[i] = math.max(heights[i], baselines[i] + _below[i]);
    }
    // 先满足被包含的短跨度；重叠跨度沿用前一步实际增长后的行高。
    _spans.sort((a, b) {
      final bySpan = a.span.compareTo(b.span);
      return bySpan != 0 ? bySpan : a.row.compareTo(b.row);
    });
    for (final s in _spans) {
      final baselineShift = s.baseline == null
          ? 0
          : baselines[s.row] - s.baseline!;
      _grow(
        s.row,
        s.span,
        math.max(s.height, s.natural + baselineShift) - gap * (s.span - 1),
        span: true,
      );
    }
    if (gridHeight != null) _grow(0, heights.length, gridHeight, span: false);
  }

  void _grow(int start, int count, double target, {required bool span}) {
    final indices = List.generate(count, (i) => i + start);
    var extra = target;
    for (final i in indices) {
      extra -= heights[i];
    }
    if (extra <= 0 || indices.isEmpty) return;
    if (!span) {
      final deficits = [
        for (final i in indices)
          math.max(0.0, _percent[i] * target - heights[i]),
      ];
      final total = deficits.fold(0.0, (a, b) => a + b);
      if (total > 0) {
        final growth = math.min(extra, total);
        for (final (j, i) in indices.indexed) {
          heights[i] += growth * deficits[j] / total;
        }
        extra -= growth;
        if (extra <= 0) return;
      }
    }
    bool constrained(int i) => _fixed[i] || (!span && _percent[i] > 0);
    var recipients = span
        ? indices.where((i) => i != start && _spanStarts.contains(i)).toList()
        : <int>[];
    var proportional = false;
    if (recipients.isEmpty) {
      final nonempty = indices.where((i) => heights[i] > 0).toList();
      recipients = nonempty.where((i) => !constrained(i)).toList();
      if (recipients.isEmpty) {
        final empty = indices.where((i) => heights[i] == 0).toList();
        if (empty.isNotEmpty && !span) {
          recipients = empty.where((i) => !constrained(i)).toList();
          if (recipients.isEmpty) recipients = empty;
        } else if (nonempty.isEmpty) {
          recipients = [indices.last];
        } else {
          recipients = nonempty;
        }
      }
      proportional = heights[recipients.first] > 0;
    }
    final weight = proportional
        ? recipients.fold(0.0, (sum, i) => sum + heights[i])
        : recipients.length;
    for (final i in recipients) {
      heights[i] += extra * (proportional ? heights[i] : 1) / weight;
    }
  }
}
