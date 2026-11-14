part of 'block_measure.dart';

extension _TextBlockMeasurement on BlockMeasurer {
  MeasuredBlock _measureText(
    ContentBlock block, {
    required bool withIndent,
    int? styleLevel,
    int sourceOffset = 0,
    bool flowPart = false,
  }) {
    final flowIndex = displayTree?.blockIndexById[block.id];
    if (!flowPart &&
        flowIndex != null &&
        ((displayTree!.flows[flowIndex]?.isNotEmpty ?? false) ||
            (displayTree!.inlineEmpty[flowIndex]?.isNotEmpty ?? false))) {
      return _measureDisplayText(
        block,
        withIndent: withIndent,
        styleLevel: styleLevel,
        sourceOffset: sourceOffset,
      );
    }
    // 样式输入统一从这一处取：正文块只有 styleId，样式在章节样式表里。
    final style = _styleOf(
      block,
      sourceOffset: sourceOffset,
      sourceEnd: sourceOffset + block.runLength,
    );
    // 书里用 p 写的标题、题记和署名也可能居中／右对齐，不能按普通正文覆盖。
    // 对齐从样式表取；这些段落不额外补两字首行缩进。
    final align = tableBody && block.kind == BlockKind.paragraph
        ? null
        : style.align;
    final sourceIndex = displayTree?.blockIndexById[block.id];
    final startsWithBlock =
        sourceOffset == 0 &&
        sourceIndex != null &&
        displayTree!.blockBoundaries(sourceIndex).contains(0);
    final insideList =
        sourceIndex != null &&
        displayTree!.chains[sourceIndex].any((c) => c.role == 'listItem');
    final sourceText = block.runs.map((r) => r.text).join();
    final linksOnly =
        DisplayLinkSemantics.onlyLinks(
          displayTree?.source,
          sourceIndex,
          sourceOffset,
          sourceText,
        ) ||
        block.runs
            .where((r) => r.text.trim().isNotEmpty)
            .every((r) => r.link != null);
    final indent =
        withIndent &&
        !_startsDisplayFormula(block, sourceOffset) &&
        !startsWithBlock &&
        !insideList &&
        !linksOnly &&
        !block.isQuoteContainer &&
        align != 'center' &&
        align != 'right';
    final prefix = indent ? options.indentPrefix : '';
    // 片段的粗体、颜色、下划线、上下标现在都在样式表里，先按 styleId 取出，
    // 再拼缩进前缀；不取这一段，正文会全部按主题默认色和普通字重绘制。
    final semantics = DisplaySemantics(
      displayTree?.source,
      sourceIndex,
      sourceOffset,
      block.runLength,
    );
    final sourceSpaces =
        displayTree?.source?.spaces[sourceIndex] ?? const <int, int>{};
    final textSymbols = bookTextSymbolOffsets(sourceText, sourceOffset);
    final splitRuns = splitDisplayRuns(block.runs, [
      ...sourceSpaces.keys,
      ...textSymbols,
    ], sourceOffset);
    final baseRuns = BlockMeasurer._withPrefix(
      _resolveRuns(semantics.splitOperators(splitRuns)),
      prefix,
      separate: textSymbols.contains(sourceOffset),
    );
    final runs = block.breaks.isEmpty
        ? baseRuns
        : BlockMeasurer._withBreaks(baseRuns, block.breaks, prefix.length);
    final textShadow = _textShadowOf(style);
    List<String>? fontFamilies(TextRun run) =>
        !options.settings.useBookFontsInSimplified
        ? null
        : styleTable?[run.styleId ?? 0].text.fontFamilies ??
              style.computed.text.fontFamilies;
    final styles = [
      for (final run in runs)
        _styles.putIfAbsent(
          (
            style.computed.text,
            fontFamilies(run),
            block.kind,
            styleLevel ?? block.level,
            run.bold,
            run.italic,
            styleTable?[run.styleId ?? 0].text.fontWeight != null,
            run.isScript ? (run.superscript ? 1 : 2) : 0,
            run.color ?? 0,
            run.sizeScale,
            ResolvedRunStyle.of(run, styleTable).hasFontSize,
            textShadow == null ? 0 : 1,
            // 0 无、1 下划线、2 删除线、3 两者都有
            (run.underline ? 1 : 0) | (run.strike ? 2 : 0),
          ),
          () => options.publicationFonts.apply(
            options.textStyleFor(
              block.kind,
              level: styleLevel ?? block.level,
              bold: run.bold,
              italic: run.italic,
              hasFontWeight:
                  styleTable?[run.styleId ?? 0].text.fontWeight != null,
              script: run.isScript ? (run.superscript ? 1 : 2) : 0,
              color: run.color == null ? null : Color(run.color!),
              sizeScale: run.sizeScale,
              hasFontSize: ResolvedRunStyle.of(run, styleTable).hasFontSize,
              shadows: textShadow,
              underline: run.underline,
              strike: run.strike,
              letterSpacing: style.letterSpacing,
              wordSpacing: style.wordSpacing,
            ),
            fontFamilies(run),
          ),
        ),
    ];
    var runOffset = -prefix.length;
    for (var i = 0; i < runs.length; i++) {
      final count = sourceSpaces[runOffset + sourceOffset];
      if (count != null && runs[i].text == ' ') {
        styles[i] = styles[i].copyWith(
          letterSpacing: _spaceWidth(styles[i]) * (count - 1),
        );
      }
      if (textSymbols.contains(runOffset + sourceOffset)) {
        styles[i] = styles[i].copyWith(
          fontFamily: 'ReaderMath',
          fontVariations: const [],
        );
      }
      if (semantics.operatorAt(math.max(0, runOffset))) {
        // 数学字体包含正确的运算符比例和数学轴；普通 serif 即使有字符也可能
        // 把箭头画得过小、过低。mo 不继承外层 strong 的文字粗体和斜体。
        styles[i] = styles[i].copyWith(
          fontFamily: 'ReaderMath',
          fontFamilyFallback: styles[i].fontFamilyFallback == null
              ? null
              : const [],
          fontVariations: styles[i].fontVariations == null ? null : const [],
          fontWeight: FontWeight.normal,
          fontStyle: FontStyle.normal,
        );
      }
      runOffset += runs[i].text.length;
    }
    final buffer = StringBuffer();
    for (final run in runs) {
      buffer.write(run.text);
    }
    final text = buffer.toString();
    // 表格单元格的边框和内边距属于单元格本身，位置已经由列宽决定；
    // 再套书里 td 的 padding 盒子会重复缩进，格内文字又提前换行。缩进来源
    // 统一由 _insetOf 决定（自己的盒子 → 列表祖先的内边距 → 阅读器兜底）。
    final spacing = _insetOf(
      block,
      style,
      sourceOffset: sourceOffset,
      sourceEnd: sourceOffset + block.runLength,
    );
    final box = spacing.box;
    final baseInset = spacing.baseInset;
    final boxed = spacing.boxed;
    final inset = spacing.left;
    final width = options.contentWidth - inset - spacing.rightSpace;
    final outerTop = spacing.outerTop;
    final outerBottom = spacing.outerBottom;
    final containerBoxes = spacing.frames;
    final bodyTop = (box?.insetTop ?? 0) + outerTop;
    final bodyBottom = (box?.insetBottom ?? 0) + outerBottom;
    final marginBase = styles.isEmpty
        ? options.settings.fontSize.toDouble()
        : (styles.first.fontSize ?? options.settings.fontSize).toDouble();
    // 原书模式的正文覆盖会去掉 p 的上外边距；简化模式采用同一规则。
    // 容器的 padding、真正的 h1～h6 和纯图片段落仍使用书内几何。
    final proseParagraph =
        sourceIndex != null &&
        displayTree?.source?.ownerOfBlock(sourceIndex)?.tag == 'p';
    double margin(int side) => side == 0 && proseParagraph
        ? 0
        : style.marginPixels(
            side,
            marginBase,
            reference: spacing.containerWidth,
            rootFontSize: options.settings.fontSize.toDouble(),
          );
    final justify = options.justifies(block.kind, align);
    final marker = BlockMeasurer._markerOf(block.kind, style);
    final shared = (
      blockId: block.id,
      kind: block.kind,
      level: block.level,
      text: text,
      runs: runs,
      runStyles: styles,
      inset: inset,
      width: width,
      align: align,
      justify: justify,
      marker: marker,
      markerInset: block.kind == BlockKind.listItem
          ? inset - options.settings.fontSize * 0.35
          : 0.0,
      hasScript: runs.any((run) => run.isScript),
      prefix: prefix.length,
    );

    if (text.isEmpty && block.inlineImages.isEmpty) {
      // 空块（例如只有样式的容器）：留一个行高的位置，不画任何东西
      return MeasuredBlock(
        blockId: block.id,
        kind: block.kind,
        level: block.level,
        text: text,
        runs: runs,
        runStyles: styles,
        height:
            options.settings.fontSize * options.settings.lineHeight +
            bodyTop +
            bodyBottom,
        inset: inset,
        layoutWidth: width,
        align: align,
        marker: marker,
        markerInset: shared.markerInset,
        justify: justify,
        hasScript: shared.hasScript,
        box: box,
        boxId: block.boxId,
        containerBoxes: containerBoxes,
        boxIndent: boxed ? baseInset : 0,
        bodyTop: bodyTop,
        bodyBottom: bodyBottom,
      );
    }

    if (block.kind == BlockKind.codeBlock) {
      return _measureCodeBlock(
        block: block,
        runs: runs,
        styles: styles,
        text: text,
        width: width,
        inset: inset,
        markerInset: shared.markerInset,
        box: box,
        textShadow: textShadow,
        align: align,
        containerBoxes: containerBoxes,
        outerTop: outerTop,
        outerBottom: outerBottom,
        useParentBox:
            displayTree?.authoritative != true && spacing.chain.isEmpty,
        sourceOffset: sourceOffset,
      );
    }

    final blockOrder = displayTree?.blockIndexById[block.id];
    final displayBoundaries = blockOrder == null
        ? const <int>{}
        : displayTree!
              .blockBoundaries(blockOrder)
              .where(
                (offset) =>
                    offset >= sourceOffset &&
                    offset <= sourceOffset + block.runLength,
              )
              .map((offset) => offset - sourceOffset)
              .toSet();
    final formulas = _formulasFor(
      block,
      sourceOffset,
      prefix.length,
      width,
      math.max(1, options.contentHeight - bodyTop - bodyBottom),
    );
    final tree = displayTree ?? formulaTree;
    final ruby = RubySource.of(tree?.source, tree?.blockIndexById[block.id])
        .where(
          (r) =>
              r.start >= sourceOffset &&
              r.end <= sourceOffset + block.runLength,
        )
        .toList();
    if (formulas.isNotEmpty ||
        ruby.isNotEmpty ||
        block.inlineImages.isNotEmpty ||
        block.inlineBoxes.isNotEmpty ||
        displayBoundaries.isNotEmpty ||
        semantics.hidden.isNotEmpty) {
      return _measureInlineText(
        block: block,
        runs: runs,
        styles: styles,
        text: text,
        width: width,
        inset: inset,
        markerInset: shared.markerInset,
        box: box,
        textShadow: textShadow,
        prefixLength: prefix.length,
        formulas: formulas,
        ruby: ruby,
        hiddenRanges: [
          for (final (a, b) in semantics.hidden)
            (a + prefix.length, b + prefix.length),
        ],
        forcedBreaks: {
          for (final offset in displayBoundaries) offset + prefix.length,
        },
        marker: marker,
        align: align,
        containerBoxes: containerBoxes,
        bodyTopOverride: outerTop,
        bodyBottomOverride: outerBottom,
        sourceOffset: sourceOffset,
        boxIndent: boxed ? baseInset : 0,
        marginTop: margin(0),
        marginBottom: margin(2),
      );
    }

    final display = ProseLineBreaks.display(text);
    var cursor = 0;
    final displayRuns = [
      for (final run in runs)
        display.text.substring(
          display.displayOffset(cursor),
          display.displayOffset(cursor += run.text.length),
        ),
    ];
    final painter = TextPainter(
      text: TextSpan(
        children: BlockMeasurer._slice(
          [for (final text in displayRuns) TextRun(text)],
          styles,
          0,
          display.text.length,
          fixedPrefixLength: prefix.length,
        ),
      ),
      textDirection: TextDirection.ltr,
      textScaler: options.textScaler,
    )..layout(maxWidth: width);

    _fitHyphenLines(painter, display, runs, styles, width);
    final metrics = painter.computeLineMetrics();
    final lines = <MeasuredLine>[];
    var total = 0.0;
    for (var i = 0; i < metrics.length; i++) {
      final height = metrics[i].height;
      total += height;
      final start = i == 0 ? 0 : lines[i - 1].end;
      final displayEnd = i == metrics.length - 1
          ? display.text.length
          : _lineStartAt(painter, metrics, i + 1, display.displayOffset(start));
      final end = display.sourceOffset(displayEnd);
      lines.add(
        MeasuredLine(
          start: start,
          end: end,
          height: height,
          width: metrics[i].width,
          hyphenated:
              i < metrics.length - 1 &&
              displayEnd > 0 &&
              display.text.codeUnitAt(displayEnd - 1) == 0x00ad &&
              display.insertions.contains(displayEnd - 1),
          hardBreak: metrics[i].hardBreak,
        ),
      );
    }
    painter.dispose();

    // 书里的外边距是相对字号写的（em），按这一块实际字号换算成像素；
    // 块与块之间的间距取「段距」与「上一块下边距 / 这一块上边距」的较大值。
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
      displayPrefixLength: prefix.length,
      align: align,
      marker: marker,
      markerInset: shared.markerInset,
      justify: justify,
      hasScript: shared.hasScript,
      box: box,
      boxId: block.boxId,
      containerBoxes: containerBoxes,
      // 列表项的列表缩进不属于盒子本身，画盒子时要扣掉
      boxIndent: boxed ? baseInset : 0,
      bodyTop: bodyTop,
      bodyBottom: bodyBottom,
      marginTop: margin(0),
      marginBottom: margin(2),
      textStyle: BlockTextStyle(shadows: textShadow),
    );
  }

  ///
  /// 列表项左侧的标记文字：有序列表用序号，无序列表用符号。
  ///
  /// 书里给了 `list-style-type`／`list-style` 就按书里的来（`none` 不画标记），
  /// 没写时按父级是 `<ol>` 还是 `<ul>` 决定数字或圆点。
}
