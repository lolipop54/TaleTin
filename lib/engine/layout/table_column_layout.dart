part of 'table_layout.dart';

/// 合并边框只算分给该格的那一半，分离边框按单元格自身的边线宽度计算。
EdgeInsets _cellContentInsets(BlockBox? box, List<double>? sharedBorders) =>
    EdgeInsets.fromLTRB(
      (box?.padLeft ?? 0) + (sharedBorders?[3] ?? box?.borderLeft ?? 0),
      (box?.padTop ?? 0) + (sharedBorders?[0] ?? box?.borderTop ?? 0),
      (box?.padRight ?? 0) + (sharedBorders?[1] ?? box?.borderRight ?? 0),
      (box?.padBottom ?? 0) + (sharedBorders?[2] ?? box?.borderBottom ?? 0),
    );

double _tableLength(Length? length, LengthContext context) =>
    length == null || length.isAuto ? 0 : math.max(0, length.resolve(context));

List<double> _fixedColumnWidths(
  ContentTable table,
  Map<ContentTableCell, ComputedStyle> cells,
  StyleTable styles,
  LayoutOptions options,
  double width,
  List<BlockBox?> boxes,
  List<EdgeInsets> cellInsets, {
  required double gap,
}) {
  // null 表示尚未指定；0px 是有效列宽，也会阻止首行再次指定这列。
  final stars = table.columnWeights;
  final widths = List<double?>.filled(table.columns, null);
  final percent = List.filled(table.columns, false);
  for (var i = 0; i < widths.length; i++) {
    final columnStyles = table.columnStyles, legacy = table.columnWidths;
    final style = columnStyles != null && i < columnStyles.length
        ? styles[columnStyles[i]]
        : null;
    final length = style?.size.width;
    if (length != null && !length.isAuto) {
      widths[i] = _tableLength(
        length,
        DisplayBoxLayout.context(style!, options, width, authorTableCell: true),
      );
      percent[i] = length is PercentLength;
    } else if (legacy != null && i < legacy.length && legacy[i] > 0) {
      widths[i] = legacy[i] * width;
      percent[i] = true;
    }
  }
  for (final (index, cell) in table.cells.indexed) {
    if (cell.row != 0) continue;
    final indices = [
      for (var c = cell.column; c < cell.column + cell.columnSpan; c++)
        if (widths[c] == null) c,
    ];
    if (indices.isEmpty) continue;
    final style = cells[cell]!;
    final context = DisplayBoxLayout.context(
      style,
      options,
      width,
      authorTableCell: true,
    );
    final box = boxes[index];
    final horizontal = cellInsets[index].horizontal;
    final size = BoxSizeResolver.widthOf(
      context,
      style.size,
      box,
      horizontalEdges: horizontal,
    );
    final content = size.definite ?? size.minimum;
    if (content != null) {
      if (style.size.width is PercentLength) {
        for (final column in indices) {
          percent[column] = true;
        }
      }
      // Chromium 先将首行格宽分到它跨过的全部列。已有 col 宽度的列优先，
      // 不会从其它列的份额中扣回差额。
      final target = math.max(
        0.0,
        content + horizontal - gap * (cell.columnSpan - 1),
      );
      for (final column in indices) {
        widths[column] = target / cell.columnSpan;
      }
    }
  }
  final assigned = _sum(widths.whereType<double>());
  final undecided = widths.where((value) => value == null).length;
  double weight(int i) =>
      stars != null && i < stars.length && stars[i] > 0 ? stars[i] : 1;
  final weights = _sum([
    for (var i = 0; i < widths.length; i++)
      if (widths[i] == null) weight(i),
  ]);
  final remaining = undecided == 0
      ? 0.0
      : math.max(0.0, width - assigned) / weights;
  final filled = [
    for (final (i, value) in widths.indexed) value ?? remaining * weight(i),
  ];
  final total = filled.fold(0.0, (sum, value) => sum + value);
  if (total > width) {
    // 百分比列合计 100% 时，padding 和合并边线也必须分到同一行里。
    // 先保留固定长度列，再在百分比列之间按比例分配剩余宽度。
    final fraction = filled.indexed
        .where((e) => percent[e.$1])
        .fold(0.0, (sum, e) => sum + e.$2);
    if (fraction == 0) return filled;
    final scale = math.max(0.0, width - (total - fraction)) / fraction;
    return [for (final (i, v) in filled.indexed) percent[i] ? v * scale : v];
  }
  return total == 0
      ? List.filled(table.columns, width / table.columns)
      : [for (final value in filled) value / total * width];
}

class _ColumnMeasure {
  double min = 0, max = 0, percent = 0, star = 0;
  bool constrained = false;
}

double _sum(Iterable<double> values) => values.fold(0.0, (a, b) => a + b);

/// 列的最小宽度来自不可折断的内容，最大宽度来自只在强制换行处分行的内容。
/// 文字使用最终排版的字体、字号和缩放率，测量不生成新的原文块或坐标。
(double, double) _contentIntrinsic(
  Iterable<String> ids,
  Map<String, ContentBlock> blocks,
  DisplayTree tree,
  StyleTable styles,
  BlockMeasurer probe,
  WhiteSpaceSpec? whiteSpace, {
  bool singleColumn = false,
}) {
  var minimum = 0.0, maximum = 0.0;
  for (final id in ids) {
    if (tree.hiddenBlocks.contains(tree.blockIndexById[id])) continue;
    final source = blocks[id]!;
    final b = probe.measure(source);
    double min = b.imageSize?.width ?? 0, max = min;
    final code = source.kind == BlockKind.codeBlock;
    if (code && singleColumn) {
      // 单列示例框没有相邻列要分宽度，直接用已经排好的代码行，省去逐字测量。
      // 一旦出现软换行，就给它当前可用的整列宽；短命令仍按自然宽度收紧。
      for (final line in b.lines) {
        max = math.max(max, line.left + line.width);
        if (!line.hardBreak) max = math.max(max, probe.options.contentWidth);
      }
    } else if (b.runs.isNotEmpty) {
      final painter = TextPainter(
        text: TextSpan(children: b.spansFor(0, b.text.length)),
        textDirection: TextDirection.ltr,
        textScaler: probe.options.textScaler,
      )..layout(maxWidth: code ? 0 : double.infinity);
      max = painter.maxIntrinsicWidth;
      if (code) {
        // 与代码行排版一致：长命令可以软折行，连续路径也只需给一个完整字形留宽。
        for (final line in painter.computeLineMetrics()) {
          min = math.max(min, line.width);
        }
      } else {
        final wrap = styles[source.styleId ?? 0].text.whiteSpace ?? whiteSpace;
        min = wrap == WhiteSpaceSpec.pre || wrap == WhiteSpaceSpec.nowrap
            ? max
            : _minimumTextWidth(b.text, painter);
      }
      painter.dispose();
    }
    if (b.inlineImages.isNotEmpty) {
      min = math.max(
        min,
        b.inlineImages.map((i) => i.size.width).reduce(math.max),
      );
      max += _sum(b.inlineImages.map((i) => i.size.width));
    }
    minimum = math.max(minimum, min);
    maximum = math.max(maximum, max);
  }
  return (minimum, maximum);
}

/// SkParagraph 的 minIntrinsicWidth 会把连续汉字当成一个词。按 Unicode
/// 提供的换行点在同一个已塑形段落中取矩形，避免对每个词重复测量。
double _minimumTextWidth(String text, TextPainter painter) {
  var start = 0, widest = 0.0;
  final unicode = lineBreakOffsets(text);
  final breaks = text.contains(' /')
      ? ({
          ...unicode,
          for (final m in RegExp(' /').allMatches(text)) m.start + 1,
        }.toList()..sort())
      : unicode;
  for (final end in breaks) {
    if (ProseLineBreaks.joinsPath(text, end)) continue;
    var last = end;
    while (last > start) {
      final unit = text.codeUnitAt(last - 1);
      if (unit != 32 && unit != 10 && unit != 13 && unit != 9) break;
      last--;
    }
    if (last > start) {
      final boxes = painter.getBoxesForSelection(
        TextSelection(baseOffset: start, extentOffset: last),
      );
      widest = math.max(widest, _sum(boxes.map((box) => box.right - box.left)));
    }
    start = end;
  }
  return widest;
}

List<double> _autoColumnWidths(
  ContentTable table,
  Map<ContentTableCell, ComputedStyle> cells,
  StyleTable styles,
  LayoutOptions options,
  double available,
  List<BlockBox?> boxes,
  List<EdgeInsets> cellInsets, {
  required double gap,
  required bool shrink,
  required double minimum,
  required Map<String, ContentBlock> blocks,
  required DisplayTree tree,
  required BlockMeasurer probe,
}) {
  final columns = List.generate(table.columns, (_) => _ColumnMeasure());
  for (final (i, c) in columns.indexed) {
    final colStyles = table.columnStyles, old = table.columnWidths;
    final style = colStyles != null && i < colStyles.length
        ? styles[colStyles[i]]
        : null;
    final width = style?.size.width;
    if ((width == null || width.isAuto) &&
        i < (table.columnWeights?.length ?? 0)) {
      c.star = table.columnWeights![i];
    }
    if (width is PercentLength) {
      c.percent = width.value;
    } else if (width != null && !width.isAuto) {
      c.min = c.max = _tableLength(
        width,
        DisplayBoxLayout.context(style!, options, available),
      );
      c.constrained = true;
    } else if (old != null && i < old.length) {
      c.percent = old[i];
    }
  }

  final spans =
      <({ContentTableCell cell, double min, double max, double percent})>[];
  for (final (i, cell) in table.cells.indexed) {
    final style = cells[cell]!, box = boxes[i];
    final edges = cellInsets[i].horizontal;
    final size = BoxSizeResolver.widthOf(
      DisplayBoxLayout.context(
        style,
        options,
        available,
        authorTableCell: true,
      ),
      style.size,
      box,
      horizontalEdges: edges,
    );
    final (intrinsicMin, intrinsicMax) = _contentIntrinsic(
      cell.blocks,
      blocks,
      tree,
      styles,
      probe,
      style.text.whiteSpace,
      singleColumn: table.columns == 1,
    );
    final specified = style.size.width;
    final percent = specified is PercentLength ? specified.value : 0.0;
    final definite = specified is PercentLength ? null : size.definite;
    final min =
        math.max(size.lower, math.max(intrinsicMin, definite ?? 0)) + edges;
    final max = math.max(
      min,
      (definite ?? size.constrain(intrinsicMax)) + edges,
    );
    if (cell.columnSpan == 1) {
      final col = columns[cell.column];
      col.min = math.max(col.min, min);
      col.max = math.max(col.max, max);
      col.constrained |= definite != null;
      col.percent = math.max(col.percent, percent);
    } else {
      spans.add((cell: cell, min: min, max: max, percent: percent));
    }
  }

  // 跨格只补所覆盖的列，中间已有的列距已算入这格的宽度。
  spans.sort((a, b) => a.cell.columnSpan.compareTo(b.cell.columnSpan));
  for (final span in spans) {
    final cell = span.cell;
    final tracks = columns.sublist(cell.column, cell.column + cell.columnSpan);
    final spacing = gap * (tracks.length - 1);
    final auto = tracks.where((c) => !c.constrained && c.percent == 0).toList();
    final grow = auto.isEmpty ? tracks : auto;
    final share = math.max(
      0.0,
      span.percent - _sum(tracks.map((c) => c.percent)),
    );
    final weights = _sum(grow.map((c) => c.max));
    for (final col in grow) {
      col.percent +=
          share * (weights == 0 ? 1 / grow.length : col.max / weights);
    }
    final low = _distributeColumns(tracks, span.min - spacing);
    for (final (i, col) in tracks.indexed) {
      col.min = math.max(col.min, low[i]);
      col.max = math.max(col.max, col.min);
    }
    final high = _distributeColumns(tracks, span.max - spacing);
    for (final (i, col) in tracks.indexed) {
      col.max = math.max(col.max, high[i]);
    }
  }
  double percentageLeft = 1;
  for (final c in columns) {
    c.percent = c.percent.clamp(0.0, percentageLeft);
    percentageLeft -= c.percent;
  }
  var preferred = _sum(columns.map((c) => c.max));
  for (final c in columns.where((c) => c.percent > 0)) {
    preferred = math.max(preferred, c.max / c.percent);
  }
  final other = _sum(columns.where((c) => c.percent == 0).map((c) => c.max));
  if (percentageLeft > 1e-8) {
    preferred = math.max(preferred, other / percentageLeft);
  } else if (other > 0) {
    preferred = double.infinity;
  }
  final target = math.max(
    minimum,
    shrink ? math.min(available, preferred) : available,
  );
  return _distributeColumns(columns, target);
}

/// 只在实际列宽超出时启动。每列先留一个字的位置，其余按已测列宽分摊；
/// 格内左右空白可缩短，边线和上下留白保留，随后用实际内宽重新断行。
void _fitColumnsToPage(
  List<double> widths,
  double available,
  ContentTable table,
  List<EdgeInsets> insets,
  List<BlockBox?> boxes,
  LayoutOptions options,
) {
  final total = _sum(widths);
  if (total <= available + 0.01) return;
  final em = options.textScaler.scale(options.settings.fontSize.toDouble());
  final base = math.min(em + 2, available / widths.length);
  final excess = _sum(widths.map((w) => math.max(0.0, w - base)));
  final remaining = available - widths.length * base;
  for (var i = 0; i < widths.length; i++) {
    widths[i] =
        base +
        (excess > 0 ? remaining * math.max(0.0, widths[i] - base) / excess : 0);
  }
  for (final (i, cell) in table.cells.indexed) {
    final p = insets[i], box = boxes[i];
    final track = _sum(
      widths.getRange(cell.column, cell.column + cell.columnSpan),
    );
    final left = box?.padLeft ?? 0, right = box?.padRight ?? 0;
    if (left + right == 0) continue;
    final edges = p.horizontal - left - right;
    final space = math.max(0.0, math.min(track * .16, track - edges - em));
    final scale = math.min(1.0, space / (left + right));
    insets[i] = EdgeInsets.fromLTRB(
      p.left - left * (1 - scale),
      p.top,
      p.right - right * (1 - scale),
      p.bottom,
    );
  }
}

/// 在四组尺寸之间插值：内容最小宽、满足百分比、满足固定长度、全部列的最大宽。
/// 超过最大宽后，剩余宽度先分给有内容且未指定宽度的列。
List<double> _distributeColumns(List<_ColumnMeasure> columns, double width) {
  if (columns.any((c) => c.star > 0)) {
    // 固定列和百分比列先占宽度，星号列按权重瓜分余量，同时保证内容最小宽度。
    final widths = [
      for (final c in columns)
        c.star > 0 ? c.min : math.max(c.max, width * c.percent),
    ];
    final active = {
      for (final (i, c) in columns.indexed)
        if (c.star > 0) i,
    };
    var room =
        width -
        _sum([
          for (final (i, v) in widths.indexed)
            if (!active.contains(i)) v,
        ]);
    while (active.isNotEmpty) {
      final unit = room / _sum(active.map((i) => columns[i].star));
      final limited = active
          .where((i) => unit * columns[i].star < columns[i].min)
          .toList();
      if (limited.isEmpty) {
        for (final i in active) {
          widths[i] = unit * columns[i].star;
        }
        break;
      }
      for (final i in limited) {
        room -= widths[i];
        active.remove(i);
      }
    }
    return widths;
  }
  var lower = [for (final c in columns) c.min];
  var total = _sum(lower);
  if (width <= total) return lower;
  for (var step = 1; step <= 3; step++) {
    final upper = [
      for (final c in columns)
        if (c.percent > 0)
          math.max(c.min, width * c.percent)
        else if (step == 3 || (step == 2 && c.constrained))
          c.max
        else
          c.min,
    ];
    final next = _sum(upper);
    if (next >= width && next > total) {
      final factor = (width - total) / (next - total);
      return [for (final (i, v) in lower.indexed) v + (upper[i] - v) * factor];
    }
    lower = upper;
    total = next;
  }
  final auto = columns.where(
    (c) => c.percent == 0 && !c.constrained && c.max > 0,
  );
  final absolute = columns.where((c) => c.percent == 0 && c.max > 0);
  final percent = columns.where((c) => c.percent > 0);
  final indices =
      (auto.isNotEmpty
              ? auto
              : absolute.isNotEmpty
              ? absolute
              : percent.isNotEmpty
              ? percent
              : columns)
          .toSet();
  double weight(_ColumnMeasure c) => c.percent > 0 ? c.percent : c.max;
  final weights = _sum(indices.map(weight));
  return [
    for (final (i, c) in columns.indexed)
      lower[i] +
          (indices.contains(c)
              ? (width - total) *
                    (weights == 0 ? 1 / indices.length : weight(c) / weights)
              : 0),
  ];
}
