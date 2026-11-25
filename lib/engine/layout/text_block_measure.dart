part of 'block_measure.dart';

// ASCII、常用中文标点及中日韩文字不含双向控制符。其它文字交给原生引擎查询逻辑行首。
final _needsLogicalLineStart = RegExp(
  r'[^\x00-\x7f\u2000-\u200a\u2010-\u2027\u3000-\u9fff\uff00-\uffef]',
);

extension _TextBlockMeasurement on BlockMeasurer {
  MeasuredBlock _measureText(
    ContentBlock block, {
    required bool withIndent,
    int? styleLevel,
    int sourceOffset = 0,
    bool flowPart = false,
  }) {
    final flowIndex = displayTree?.blockIndexById[block.id];
    final candidates = sourceOffset == 0 && !flowPart
        ? _inlineCandidates(block)
        : const <DisplayNode>[];
    final tryColumns = candidates.where(_isSizedInlineBox).length >= 2;
    final hasDisplayFlow =
        flowIndex != null &&
        ((displayTree!.flows[flowIndex]?.isNotEmpty ?? false) ||
            (displayTree!.inlineEmpty[flowIndex]?.isNotEmpty ?? false));
    if (!flowPart && hasDisplayFlow && !tryColumns) {
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
    final rtl = style.computed.table.direction == 'rtl';
    final align = tableBody && block.kind == BlockKind.paragraph
        ? null
        : style.align ??
              (rtl &&
                          (style.computed.block.textAlign == null ||
                              style.computed.block.textAlign ==
                                  TextAlignSpec.start) ||
                      !rtl &&
                          style.computed.block.textAlign == TextAlignSpec.end
                  ? 'right'
                  : null);
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
    final cssIndent = displayTree?.authoritative == true
        ? style.computed.block.textIndent
        : null;
    final canIndent =
        (withIndent || (sourceOffset == 0 && cssIndent != null)) &&
        !_startsDisplayFormula(block, sourceOffset) &&
        !startsWithBlock &&
        (!insideList || cssIndent != null) &&
        displayTree?.legends.containsKey(sourceIndex) != true &&
        !linksOnly &&
        (!block.isQuoteContainer || cssIndent != null) &&
        align != 'center' &&
        align != 'right';
    // 片段的粗体、颜色、下划线、上下标现在都在样式表里，先按 styleId 取出，
    // 再拼缩进前缀；不取这一段，正文会全部按主题默认色和普通字重绘制。
    final semantics = DisplaySemantics(
      displayTree?.source,
      sourceIndex,
      sourceOffset,
      block.runLength,
    );
    final hiddenRanges = <(int, int)>[
      ...semantics.hidden,
      for (final (start, end)
          in displayTree?.hiddenText[sourceIndex] ?? const <(int, int)>[])
        if (start < sourceOffset + block.runLength && end > sourceOffset)
          (
            (start - sourceOffset).clamp(0, block.runLength),
            (end - sourceOffset).clamp(0, block.runLength),
          ),
      for (final offset in block.breaks)
        if (displayTree?.hiddenBreaks[sourceIndex]?.contains(
              offset + sourceOffset,
            ) ==
            true)
          (offset, offset + 1),
    ];
    var hiddenThrough = 0;
    for (final (start, end)
        in hiddenRanges..sort((a, b) => a.$1.compareTo(b.$1))) {
      if (start > hiddenThrough) break;
      hiddenThrough = math.max(hiddenThrough, end);
    }
    // 开关仍控制普通段落；精排段落写明 0 或其它距离时，按作者指定的量测。
    final useIndent = canIndent && hiddenThrough < block.runLength;
    // 等宽的 2em 沿用现有的两全角缩进，保持字形和点击坐标的计算方式。
    final sameAsReaderIndent =
        cssIndent is EmLength &&
        cssIndent.value == 2 &&
        (_lengthContext(style.computed, options.contentWidth).fontSize -
                    options.textScaler.scale(
                      options.settings.fontSize.toDouble(),
                    ))
                .abs() <
            .001;
    final hasAuthorIndent =
        cssIndent != null && !cssIndent.isAuto && !sameAsReaderIndent;
    final prefix = useIndent && !hasAuthorIndent ? options.indentPrefix : '';
    final sourceSpaces =
        displayTree?.source?.spaces[sourceIndex] ?? const <int, int>{};
    final wideSpaces =
        displayTree?.source?.wideSpaces[sourceIndex] ?? const <int, int>{};
    final textSymbols = bookTextSymbolOffsets(sourceText, sourceOffset);
    // 持久正文把 HTML 空白规范为一个字符。格内测宽和实际断行都恢复
    // 书里不换行空格的语义，每个显示字符仍对应原来的一个 UTF-16 单元。
    final nonBreakingSpaces = authorTableCell
        ? displayTree?.source?.nonBreakingSpaces[sourceIndex] ??
              const <int, int>{}
        : const <int, int>{};
    final splitRuns = splitDisplayRuns(
      block.runs,
      [
        ...nonBreakingSpaces.keys,
        ...sourceSpaces.keys,
        ...wideSpaces.keys,
        ...textSymbols,
      ],
      sourceOffset,
      nonBreakingSpaces: nonBreakingSpaces,
    );
    final baseRuns = BlockMeasurer._withPrefix(
      _resolveRuns(semantics.splitOperators(splitRuns)),
      prefix,
      separate: textSymbols.contains(sourceOffset),
    );
    final runs = block.breaks.isEmpty
        ? baseRuns
        : BlockMeasurer._withBreaks(baseRuns, block.breaks, prefix.length);
    final textShadow = _textShadowOf(style);
    final authorHeight =
        flatNest ||
        tryColumns ||
        (displayTree?.frameLabels.contains(sourceIndex) ?? false);
    // 行内块里的文字和背景必须按同一行高测量。范围来自原书节点，
    // 因此数字外层再套一层链接或粗体时也能取到，普通正文沿用阅读设置。
    final inlineRanges = [
      if (!authorHeight && sourceIndex != null)
        for (final node in _inlineCandidates(block))
          if (node.display == DisplaySpec.inlineBlock)
            ?_textRange(node, sourceIndex),
    ];
    var offset = sourceOffset - prefix.length, rangeIndex = 0;
    final styles = <TextStyle>[];
    final nowrap = <(int, int)>[];
    final softBreaks = {
      for (final pos in displayTree?.softBreaks[sourceIndex] ?? const <int>{})
        if (pos >= sourceOffset && pos <= sourceOffset + block.runLength)
          pos - sourceOffset + prefix.length,
    };
    var wrapOffset = 0;
    final marks = <int, ({int end, String text, bool below, Color? color})>{};
    for (final run in runs) {
      final end = offset + run.text.length;
      final runText = styleTable?[run.styleId ?? 0].text;
      if (runText?.emphasis case final String mark when mark.isNotEmpty) {
        var at = wrapOffset;
        for (final char in run.text.characters) {
          final end = at + char.length;
          if (_takesEmphasis(char) && at >= prefix.length) {
            final color = runText?.emphasisColor?.argb;
            marks[at] = (
              end: end,
              text: mark,
              below: runText?.emphasisPosition?.contains('under') == true,
              color: color == null ? null : Color(color),
            );
          }
          at = end;
        }
      }
      final whiteSpace =
          styleTable?[run.styleId ?? 0].text.whiteSpace ??
          style.computed.text.whiteSpace;
      if (whiteSpace == WhiteSpaceSpec.nowrap) {
        if (nowrap.isNotEmpty && nowrap.last.$2 == wrapOffset) {
          nowrap[nowrap.length - 1] = (
            nowrap.last.$1,
            wrapOffset + run.text.length,
          );
        } else {
          nowrap.add((wrapOffset, wrapOffset + run.text.length));
        }
      }
      wrapOffset += run.text.length;
      while (rangeIndex < inlineRanges.length &&
          inlineRanges[rangeIndex].end <= offset) {
        rangeIndex++;
      }
      styles.add(
        _textRunStyle(
          block,
          style,
          run,
          styleLevel: styleLevel,
          useAuthorHeight:
              authorHeight ||
              (rangeIndex < inlineRanges.length &&
                  inlineRanges[rangeIndex].start < end),
          textShadow: textShadow,
        ),
      );
      offset = end;
    }
    final textGaps = <int, ({double width, bool includesSpace})>{};
    var runOffset = -prefix.length;
    for (var i = 0; i < runs.length; i++) {
      final count = sourceSpaces[runOffset + sourceOffset];
      final wide = wideSpaces[runOffset + sourceOffset];
      if (wide != null && runOffset > 0) {
        // 全角留白可能保留为一个普通空格，也可能已经裁掉。统一在
        // 换行测量中分配宽度，避免 TextPainter 把独立空格当行尾丢掉。
        textGaps[runOffset + prefix.length] = (
          width:
              options.textScaler.scale(
                styles[i].fontSize ?? options.settings.fontSize.toDouble(),
              ) *
              wide,
          includesSpace: runs[i].text == ' ',
        );
      } else if ((runs[i].text == ' ' || runs[i].text == '\u00a0') &&
          count != null) {
        final style = styles[i];
        final space = _spaceWidth(style);
        styles[i] = style.copyWith(letterSpacing: space * (count - 1));
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
    final marginBase = styles.isEmpty
        ? options.settings.fontSize.toDouble()
        : (styles.first.fontSize ?? options.settings.fontSize).toDouble();
    // 表格单元格的边框和内边距属于单元格本身，位置已经由列宽决定；
    // 再套书里 td 的 padding 盒子会重复缩进，格内文字又提前换行。缩进来源
    // 统一由 _insetOf 决定（自己的盒子 → 列表祖先的内边距 → 阅读器兜底）。
    final marker = BlockMeasurer._markerOf(block.kind, style);
    final floatDecorations = sourceIndex != null && sourceOffset == 0
        ? _emptyFloatsBeside(sourceIndex)
        : null;
    final spacing = _insetOf(
      block,
      style,
      merged: floatDecorations?.nodes ?? const [],
      marker: marker,
      markerStyle: styles.firstOrNull,
      sourceOffset: sourceOffset,
      sourceEnd: sourceOffset + block.runLength,
      marginFontSize: marginBase,
    );
    final box = spacing.box;
    final baseInset = spacing.baseInset;
    final boxed = spacing.boxed;
    final contentLeft = spacing.left + (floatDecorations?.left ?? 0);
    final contentRight =
        options.contentWidth -
        spacing.rightSpace -
        (floatDecorations?.right ?? 0);
    // 浮动只占用行宽。段内百分比仍以段落本来的内容宽度计算。
    final inset = math.max(contentLeft, floatLineEdges?.left ?? contentLeft);
    final width = math.max(
      0.0,
      math.min(contentRight, floatLineEdges?.right ?? contentRight) - inset,
    );
    final contentWidth = contentRight - contentLeft;
    final firstLineIndent = useIndent && hasAuthorIndent && sourceOffset == 0
        ? cssIndent
              .resolve(_lengthContext(style.computed, contentWidth))
              .clamp(-math.max(0.0, inset), math.max(0.0, width - 1))
              .toDouble()
        : 0.0;
    // 原文会裁掉段首换行，按显示树恢复真实 br 的空行高度，保持原文字位不动。
    final leading = sourceOffset == 0
        ? displayTree?.leadingBreaks[sourceIndex] ?? 0
        : 0;
    final outerTop =
        spacing.outerTop +
        (leading == 0
            ? 0
            : leading * _lineStrut(_paragraphFont(block, sourceOffset)).height);
    final outerBottom = spacing.outerBottom;
    final containerBoxes = [...spacing.frames, ...?floatDecorations?.frames];
    final bodyTop = (box?.insetTop ?? 0) + outerTop;
    final bodyBottom = (box?.insetBottom ?? 0) + outerBottom;
    final heightSpec = flatNest
        ? const BoxAxisSize(null, null, null)
        : spacing.ownerHeight ??
              BoxSizeResolver.heightOf(
                _lengthContext(style.computed, spacing.containerWidth),
                style.computed.size,
                box,
                parentHeight: spacing.containerHeight,
              );
    // 简化阅读的段落保留全部文字。明确给出的高度可增加段内留白，
    // 高度不足以容纳正文时继续排完，避免下一段盖住文字。
    double tailSpace(double natural) => math.max(
      0,
      math.min(
            heightSpec.use(natural),
            options.contentHeight - bodyTop - bodyBottom,
          ) -
          natural,
    );
    double margin(int side) => style.marginPixels(
      side,
      marginBase,
      reference: spacing.marginReference,
      rootFontSize: options.settings.fontSize.toDouble(),
    );
    final justify = options.justifies(block.kind, align);
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
          ? inset - options.listMarkerGap
          : 0.0,
      hasScript: runs.any((run) => run.isScript),
      prefix: prefix.length,
    );

    if (text.isEmpty && block.inlineImages.isEmpty) {
      // 空块（例如只有样式的容器）：留一个行高的位置，不画任何东西
      final natural = options.settings.fontSize * options.settings.lineHeight;
      final tail = bodyBottom + tailSpace(natural);
      return MeasuredBlock(
        blockId: block.id,
        kind: block.kind,
        level: block.level,
        text: text,
        runs: runs,
        runStyles: styles,
        height: natural + bodyTop + tail,
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
        bodyBottom: tail,
        flowMargins: spacing.margins,
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
    final simpleText =
        prefix.isEmpty &&
        firstLineIndent == 0 &&
        block.inlineImages.isEmpty &&
        formulas.isEmpty &&
        ruby.isEmpty &&
        hiddenRanges.isEmpty &&
        textGaps.isEmpty;
    final columns = tryColumns && simpleText
        ? _measureInlineColumns(
            block,
            runs,
            styles,
            text,
            width,
            displayBoundaries,
            heightSpec.definite,
          )
        : null;
    if (tryColumns && columns == null && hasDisplayFlow) {
      return _measureDisplayText(
        block,
        withIndent: withIndent,
        styleLevel: styleLevel,
        sourceOffset: sourceOffset,
      );
    }
    final floated =
        candidates.isNotEmpty &&
            simpleText &&
            columns == null &&
            block.inlineBoxes.isEmpty
        ? _leadingFloat(block, runs, styles, text, width)
        : null;
    if (formulas.isNotEmpty ||
        ruby.isNotEmpty ||
        block.inlineImages.isNotEmpty ||
        block.inlineBoxes.isNotEmpty ||
        textGaps.isNotEmpty ||
        firstLineIndent != 0 ||
        marks.isNotEmpty ||
        nowrap.isNotEmpty ||
        softBreaks.isNotEmpty ||
        displayBoundaries.isNotEmpty ||
        hiddenRanges.isNotEmpty ||
        candidates.any((n) => n.display == DisplaySpec.inlineBlock) ||
        columns != null ||
        floated != null) {
      final measured = _measureInlineText(
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
          for (final (a, b) in hiddenRanges)
            (a + prefix.length, b + prefix.length),
        ],
        forcedBreaks: {
          for (final offset in displayBoundaries) offset + prefix.length,
        },
        textGaps: textGaps,
        firstLineIndent: firstLineIndent,
        nowrap: nowrap,
        rtl: rtl,
        marks: marks,
        softBreaks: softBreaks,
        contentWidth: contentWidth,
        parentHeight: heightSpec.definite,
        columns: columns,
        leadingFloat: floated,
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
      return spacing.margins == null
          ? measured
          : measured.withBoxEdges(
              first: measured.boxFirst,
              last: measured.boxLast,
              flowMargins: spacing.margins,
            );
    }

    final display = authorTableCell
        ? ProseLineBreaks.tableText(
            text,
            hyphenate: style.computed.text.hyphens == 'auto',
          )
        : ProseLineBreaks.display(text);
    var cursor = 0;
    final displayRuns = [
      for (final run in runs)
        display.text.substring(
          display.displayOffset(cursor),
          display.displayOffset(cursor += run.text.length),
        ),
    ];
    final pending = paragraphs;
    // 自动断字、行尾折叠和上下标会改变最终画出的文字，仍走片段绘制。
    final ink =
        pending != null &&
            !shared.hasScript &&
            display.insertions.isEmpty &&
            !text.endsWith(' ') &&
            !text.endsWith('\n')
        ? pending.foreground(block.kind == BlockKind.caption)
        : null;
    final painter = TextPainter(
      text: TextSpan(
        children: BlockMeasurer._slice(
          [for (final text in displayRuns) TextRun(text)],
          ink == null
              ? styles
              : [
                  for (final style in styles)
                    style.color == null ? style.copyWith(color: ink) : style,
                ],
          0,
          display.text.length,
          fixedPrefixLength: prefix.length,
        ),
      ),
      textAlign: TextAlign.left,
      textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
      textScaler: options.textScaler,
      // SkParagraph 以单精度保存字宽。在 16.8px 这样的单字列里，
      // 约束恰好落在字宽的舍入边界时可能一行塞两个字。只补浮点误差，
      // 实际盒宽、绘制起点和选文坐标仍取原书尺寸。
    )..layout(maxWidth: width + .0001);

    _fitHyphenLines(painter, display, runs, styles, width);
    // Flutter 的 LineMetrics.height 取整。作者格内同字号、同行高的普通
    // 文字使用 CSS 行高，避免很多行接排时逐行积累小数误差。
    double? cssLineHeight;
    if (authorTableCell &&
        styles.isNotEmpty &&
        style.computed.text.lineHeight != null) {
      final first = styles.first;
      if (first.height != null &&
          first.fontSize != null &&
          styles.every(
            (s) => s.fontSize == first.fontSize && s.height == first.height,
          )) {
        cssLineHeight =
            options.textScaler.scale(first.fontSize!) * first.height!;
      }
    }
    final metrics = painter.computeLineMetrics();
    final simpleLtr =
        metrics.length > 1 &&
        !rtl &&
        !_needsLogicalLineStart.hasMatch(display.text);
    final lines = <MeasuredLine>[];
    var total = 0.0;
    for (var i = 0; i < metrics.length; i++) {
      final height = cssLineHeight ?? metrics[i].height;
      total += height;
      final start = i == 0 ? 0 : lines[i - 1].end;
      final displayEnd = i == metrics.length - 1
          ? display.text.length
          : _lineStartAt(
              painter,
              metrics,
              i + 1,
              display.displayOffset(start),
              simpleLtr: simpleLtr,
            );
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
    if (ink != null &&
        pending != null &&
        (lines.length == 1 ||
            !justify && align != 'center' && align != 'right')) {
      pending.keep(lines, width, text.length, painter);
    } else {
      painter.dispose();
    }

    // 书里的外边距是相对字号写的（em），按这一块实际字号换算成像素；
    // 块流使用与祖先合并后的边距，保留自身值供样式检查。
    final tail = bodyBottom + tailSpace(total);
    return MeasuredBlock(
      blockId: block.id,
      kind: block.kind,
      level: block.level,
      text: text,
      runs: runs,
      runStyles: styles,
      lines: lines,
      height: total + bodyTop + tail,
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
      bodyBottom: tail,
      marginTop: margin(0),
      marginBottom: margin(2),
      flowMargins: spacing.margins,
      textStyle: BlockTextStyle(shadows: textShadow, rtl: rtl),
    );
  }

  TextStyle _specifiedLineHeight(
    TextStyle text,
    LineHeightSpec? lineHeight, {
    required bool useAuthorHeight,
  }) {
    if (!useAuthorHeight) return text;
    final size = text.fontSize;
    if (lineHeight == null || size == null || size <= 0) return text;
    final pixels = lineHeight.resolvePx(
      fontSize: size,
      rootFontSize: options.settings.fontSize.toDouble(),
    );
    return pixels == null
        ? text
        : text.copyWith(
            height: (pixels / size).clamp(.5, 5),
            leadingDistribution: authorTableCell
                ? TextLeadingDistribution.even
                : text.leadingDistribution,
          );
  }

  ///
  /// 列表项左侧的标记文字：有序列表用序号，无序列表用符号。
  ///
  /// 书里给了 `list-style-type`／`list-style` 就按书里的来（`none` 不画标记），
  /// 没写时按父级是 `<ol>` 还是 `<ul>` 决定数字或圆点。
  TextStyle _textRunStyle(
    ContentBlock block,
    ResolvedBlockStyle style,
    TextRun run, {
    int? styleLevel,
    bool useAuthorHeight = false,
    List<Shadow>? textShadow,
  }) {
    List<String>? fontFamilies(TextRun run) =>
        !options.settings.useBookFontsInSimplified
        ? null
        : styleTable?[run.styleId ?? 0].text.fontFamilies ??
              style.computed.text.fontFamilies;
    final language =
        styleTable?[run.styleId ?? 0].text.language ??
        style.computed.text.language;
    return _styles.putIfAbsent(
      (
        style.computed.text,
        language,
        flatNest || useAuthorHeight
            ? (styleTable?[run.styleId ?? 0].text.lineHeight)
            : null,
        fontFamilies(run),
        block.kind,
        styleLevel ?? block.level,
        run.bold,
        run.italic,
        styleTable?[run.styleId ?? 0].text.fontWeight != null,
        run.isScript ? (run.superscript ? 1 : 2) : 0,
        run.color ?? 0,
        styleTable?[run.styleId ?? 0].text.decoration,
        run.sizeScale,
        _runStyleOf(run).hasFontSize,
        textShadow == null ? 0 : 1,
        // 0 无、1 下划线、2 删除线、3 两者都有
        (run.underline ? 1 : 0) | (run.strike ? 2 : 0),
      ),
      () => _specifiedLineHeight(
        options.publicationFonts
            .apply(
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
                hasFontSize: _runStyleOf(run).hasFontSize,
                shadows: textShadow,
                underline: run.underline,
                strike: run.strike,
                bookDecoration: styleTable?[run.styleId ?? 0].text.decoration,
                letterSpacing: style.letterSpacing,
                wordSpacing: style.wordSpacing,
              ),
              fontFamilies(run),
            )
            .copyWith(locale: bookLocale(language)),
        styleTable?[run.styleId ?? 0].text.lineHeight,
        useAuthorHeight: flatNest || useAuthorHeight,
      ),
    );
  }
}

// CSS 着重号跳过空白、分隔符、控制字符和标准列明的连接号。
final _emphasisExcluded = RegExp(
  r'^[\p{Z}\p{Cc}\p{Cf}\u002d\u058a\u05be\u1400\u2010-\u2014\u2027\u30fb]',
  unicode: true,
);
bool _takesEmphasis(String grapheme) => !_emphasisExcluded.hasMatch(grapheme);
