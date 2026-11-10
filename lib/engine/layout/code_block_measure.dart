part of 'block_measure.dart';

extension _CodeBlockMeasurement on BlockMeasurer {
  /// 每个源码行按自己的缩进量宽；额外保留包住代码框的引用容器。
  MeasuredBlock _measureCodeBlock({
    required ContentBlock block,
    required List<TextRun> runs,
    required List<TextStyle> styles,
    required String text,
    required double width,
    required double inset,
    required double markerInset,
    required BlockBox? box,
    required List<Shadow>? textShadow,
    required String? align,
    List<ContainerBoxFrame> containerBoxes = const [],
    double outerTop = 0,
    double outerBottom = 0,
    bool useParentBox = true,
    int sourceOffset = 0,
  }) {
    final parent = useParentBox ? block.parentBox : null;
    final outer = parent == null
        ? null
        : _boxFromRaw(
            ResolvedBlockStyle.of(
              ContentBlock(
                id: block.id,
                kind: block.kind,
                styleId: parent.styleId,
              ),
              table: styleTable,
            ).rawBox,
            options.settings.fontSize.toDouble(),
          );
    // 内框的内边距已在 width/inset 中；这里只再扣外层引用框的内边距。
    final inner = outer == null ? null : box;
    width -= (outer?.insetLeft ?? 0) + (outer?.insetRight ?? 0);
    inset += outer?.insetLeft ?? 0;
    final fontSize =
        styles.first.fontSize ?? options.settings.fontSize.toDouble();
    final style = _styleOf(block);
    final codeTop = outer == null
        ? 0.0
        : (inner?.insetTop ?? 0) + style.marginPixels(0, fontSize);
    final codeBottom = outer == null
        ? 0.0
        : (inner?.insetBottom ?? 0) + style.marginPixels(2, fontSize);
    final bodyTop = outer == null
        ? (box?.insetTop ?? 0) + outerTop
        : outer.insetTop + codeTop;
    final bodyBottom = outer == null
        ? (box?.insetBottom ?? 0) + outerBottom
        : outer.insetBottom + codeBottom;
    final spaceWidth = _spaceWidth(styles.first);
    final starts = <int>[0];
    for (var i = 0; i < text.length; i++) {
      if (text.codeUnitAt(i) == 0x0A) starts.add(i + 1);
    }
    final blockIndex = displayTree?.blockIndexById[block.id];
    final sourceLines = <int, int>{
      for (final entry
          in (displayTree?.source?.codeLines[blockIndex] ?? const <int, int>{})
              .entries)
        if (entry.key >= sourceOffset && entry.key < sourceOffset + text.length)
          entry.key - sourceOffset: entry.value,
    };
    starts.addAll(sourceLines.keys.where((p) => !starts.contains(p)));
    starts.sort();
    final lines = <MeasuredLine>[];
    var total = 0.0;
    for (var li = 0; li < starts.length; li++) {
      final start = starts[li];
      final lastTextLine = li + 1 >= starts.length;
      // 本行文字范围（不含换行符）；换行符并进本行末尾，保证各行范围首尾相接
      final next = lastTextLine ? text.length : starts[li + 1];
      final hasNewline = next > start && text.codeUnitAt(next - 1) == 0x0A;
      final end = hasNewline ? next - 1 : next;
      if (end < start) continue;
      // indents[i] 是第 i 个换行之后那一行的缩进，即文本行 li 的缩进
      final indentCount =
          sourceLines[start] ??
          (li == 0 || li - 1 >= block.indents.length
              ? 0
              : block.indents[li - 1]);
      // 缩进再深也要给正文留出空间，否则这一行会画到页面外面
      final minWidth = width * 0.25;
      final left = math.min<double>(
        indentCount * spaceWidth,
        math.max(0, width - minWidth),
      );
      final available = width - left;
      final painter = TextPainter(
        text: TextSpan(
          children: BlockMeasurer._slice(runs, styles, start, end),
        ),
        textDirection: TextDirection.ltr,
        textScaler: options.textScaler,
      )..layout(maxWidth: available);
      final metrics = painter.computeLineMetrics();
      var previousEnd = 0;
      for (var i = 0; i < metrics.length; i++) {
        final lineStart = i == 0
            ? 0
            : _lineStartAt(painter, metrics, i, previousEnd);
        final lineEnd = i == metrics.length - 1
            ? end - start
            : _lineStartAt(painter, metrics, i + 1, lineStart);
        lines.add(
          MeasuredLine(
            start: start + lineStart,
            end: (i == metrics.length - 1 && hasNewline)
                ? start + lineEnd + 1
                : start + lineEnd,
            height: metrics[i].height,
            width: metrics[i].width,
            hardBreak:
                metrics[i].hardBreak ||
                (i == metrics.length - 1 && !lastTextLine),
            left: left,
          ),
        );
        total += metrics[i].height;
        previousEnd = lineEnd;
      }
      painter.dispose();
    }
    return MeasuredBlock(
      blockId: block.id,
      kind: block.kind,
      level: block.level,
      text: text,
      runs: runs,
      runStyles: styles,
      lines: lines,
      height: total + bodyTop + bodyBottom,
      inset: inset,
      layoutWidth: width,
      displayPrefixLength: 0,
      align: align,
      marker: null,
      markerInset: markerInset,
      justify: false,
      hasScript: runs.any((run) => run.isScript),
      box: outer ?? box,
      boxId: outer == null ? block.boxId : parent!.id,
      containerBoxes: containerBoxes,
      boxIndent: inner?.insetLeft ?? 0,
      codeBox: inner,
      codeTop: codeTop,
      codeBottom: codeBottom,
      bodyTop: bodyTop,
      bodyBottom: bodyBottom,
      textStyle: BlockTextStyle(shadows: textShadow),
    );
  }
}
