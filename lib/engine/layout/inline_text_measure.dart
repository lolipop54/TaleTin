part of 'block_measure.dart';

extension _InlineTextMeasurement on BlockMeasurer {
  /// 图片和行内盒子的测量：按实际图片尺寸、文字范围及内边距逐行断行。
  ///
  /// 只有存在行内图片或行内盒子时使用；普通正文仍交给 TextPainter 整块
  /// 断行。行内图片比文字高时把这一行撑高，文字在行内垂直居中。
  MeasuredBlock _measureInlineText({
    required ContentBlock block,
    required List<TextRun> runs,
    required List<TextStyle> styles,
    required String text,
    required double width,
    required double contentWidth,
    double? parentHeight,
    int? insideInline,
    required double inset,
    required double markerInset,
    required BlockBox? box,
    required List<Shadow>? textShadow,
    required int prefixLength,
    required String? marker,
    required String? align,
    required double boxIndent,
    required double marginTop,
    required double marginBottom,
    List<_InlineSpec> formulas = const [],
    List<_InlineSpec>? preparedImages,
    List<RubyRange> ruby = const [],
    Set<int> forcedBreaks = const {},
    Map<int, ({double width, bool includesSpace})> textGaps = const {},
    double firstLineIndent = 0,
    List<(int, int)> nowrap = const [],
    Set<int> softBreaks = const {},
    bool rtl = false,
    Map<int, ({int end, String text, bool below, Color? color})> marks =
        const {},
    MeasuredLine? columns,
    ({int end, MeasuredSegment glyph, double width, double height})?
    leadingFloat,
    List<(int, int)> hiddenRanges = const [],
    List<ContainerBoxFrame> containerBoxes = const [],
    double bodyTopOverride = 0,
    double bodyBottomOverride = 0,
    int sourceOffset = 0,
  }) {
    final blockIndex = displayTree?.blockIndexById[block.id];
    final atoms = columns != null || blockIndex == null
        ? const <_InlineSpec>[]
        : _inlineTextBoxes(
            block,
            runs,
            styles,
            text,
            contentWidth,
            parentHeight,
            blockIndex,
            prefixLength - sourceOffset,
            hiddenRanges,
            ruby,
            formulas,
            forcedBreaks,
            prefixLength,
            insideInline,
          );
    bool owned(int id) =>
        (insideInline == null ||
            (id != insideInline && _insideInline(id, insideInline))) &&
        atoms.every((a) => !_insideInline(id, a.elementId));
    final blanks = _blankLineHeights(
      block,
      blockIndex,
      sourceOffset,
      prefixLength,
      owned,
    );
    final images = <_InlineSpec>[
      ...atoms,
      ...formulas,
      ...preparedImages ??
          _paragraphImages(
            block,
            contentWidth,
            parentHeight,
            sourceOffset,
            prefixLength,
            text.length,
            styles.firstOrNull,
          ).where((im) => owned(im.elementId)),
    ]..sort((a, b) => a.offset.compareTo(b.offset));
    final spans = [
      for (final span in block.inlineBoxes)
        if (displayTree?.hiddenElements.contains(span.id) != true &&
            owned(span.id))
          span.shifted(prefixLength),
    ];
    final label = displayTree?.frameLabels.contains(blockIndex) == true;
    final topEdge =
        label && containerBoxes.any((f) => f.first && f.box.borderTop > 0);
    final bottomEdge =
        label && containerBoxes.any((f) => f.last && f.box.borderBottom > 0);
    final baseSize = styles.isEmpty
        ? options.settings.fontSize.toDouble()
        : ((styles.first.fontSize ?? options.settings.fontSize.toDouble()) /
              runs.first.sizeScale);
    final boxes = {
      for (final span in spans)
        span.id: span.styleId == null
            ? _boxFromRaw(
                span.box,
                options.textScaler.scale(baseSize * span.scale),
              )!
            : resolveBlockBox(
                styleTable![span.styleId!].box,
                _lengthContext(styleTable![span.styleId!], width),
              )!,
    };
    final boxPlacements = <InlineBoxPlacement>[];
    // 段首的大字号 span 只影响它所在的行，不能充当后续行里的父字体。
    final strut = _lineStrut(
      images.any((i) => i.verticalAlign == 'baseline')
          ? _paragraphFont(block, sourceOffset)
          : styles.firstOrNull,
    );
    final fallbackHeight = strut.height;
    final lines = <MeasuredLine>[];
    final placements = <InlineImagePlacement>[];
    var total = 0.0;

    var lineStart = 0;
    var cursor = leadingFloat?.end ?? 0;
    var lineX = leadingFloat?.width ?? firstLineIndent;
    var textHeight = 0.0;
    var textAscent = 0.0, textDescent = 0.0;
    var imageHeight = 0.0;
    var hardBreak = false;
    var hasContent = false;
    var segments = <MeasuredSegment>[];
    var pending = <_InlineSpec>[];

    void finishLine() {
      if (!hasContent) return;
      // 固定内边距不拉伸，只把正文的行尾空档分配到文字之间。分段绘制、
      // 选文和听书都保存并使用同一个字距，不能因新增彩色 span 取消两端对齐。
      if (pending.every((e) => e.textBox == null) &&
          options.justifies(block.kind, align) &&
          !hardBreak &&
          cursor < text.length) {
        final justified = _justifyInlineLine(
          segments,
          pending,
          runs,
          styles,
          prefixLength,
          width - lineX,
          options.textScaler,
        );
        segments = justified.$1;
        pending = justified.$2;
        lineX += justified.$3;
      }
      final contentHeight = textHeight > 0
          ? math.max(textHeight, textAscent + textDescent)
          : fallbackHeight;
      final active = spans
          .where((s) => s.start < cursor && s.end > lineStart)
          .toList();
      var above = textAscent;
      var below = textHeight > 0 ? contentHeight - textAscent : 0.0;
      for (final segment in segments) {
        if (segment.ruby case final label?) {
          if (label.below) {
            below = math.max(
              below,
              contentHeight - segment.baseline + label.height,
            );
          } else {
            above = math.max(above, segment.baseline + label.height);
          }
        }
      }
      final rowBoxes = <InlineBoxSpan, Rect>{};
      for (final span in active.reversed) {
        final covered = segments
            .where((s) => s.start < span.end && s.end > span.start)
            .toList();
        if (covered.isEmpty) continue;
        final decoration = boxes[span.id]!;
        final first = span.first && span.start >= lineStart,
            last = span.last && span.end <= cursor;
        // 普通 span 的底色按本身的字体盒绘制，共用本行文字的基线。
        // 不能把行距或同一行里更大的文字算进小字号装饰的高度。
        final inlineBlock =
            span.styleId != null &&
            styleTable![span.styleId!].block.display == DisplaySpec.inlineBlock;
        final textSpans = BlockMeasurer._slice(
          runs,
          styles,
          math.max(span.start, covered.first.start),
          math.min(span.end, covered.last.end),
        );
        final painter = TextPainter(
          text: TextSpan(
            children: inlineBlock
                ? textSpans
                : [
                    for (final span in textSpans.cast<TextSpan>())
                      TextSpan(
                        text: span.text,
                        style: span.style!.copyWith(height: kTextHeightNone),
                      ),
                  ],
          ),
          textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
          textScaler: options.textScaler,
        )..layout();
        final metrics = painter.computeLineMetrics().first;
        painter.dispose();
        var rect = Rect.fromLTRB(
          covered.first.left,
          -metrics.ascent,
          covered.last.left + covered.last.width,
          metrics.descent,
        );
        // 外层盒子必须包住内层的边框和内边距。
        for (final child in rowBoxes.entries.where(
          (b) => b.key.start >= span.start && b.key.end <= span.end,
        )) {
          rect = rect.expandToInclude(child.value);
        }
        rect = Rect.fromLTRB(
          rect.left - (first ? decoration.insetLeft : 0),
          rect.top - decoration.insetTop,
          rect.right + (last ? decoration.insetRight : 0),
          rect.bottom + decoration.insetBottom,
        );
        rowBoxes[span] = rect;
        // 装饰已经落在行距里时不再加高；越界时只补需要的空间，防止分页裁掉。
        above = math.max(above, -rect.top);
        below = math.max(below, rect.bottom);
      }
      final (height, baseline) = _alignInlineObjects(
        pending,
        above: above,
        below: below,
        contentHeight: contentHeight,
        imageHeight: imageHeight,
        strut: strut,
      );
      final lineIndex = lines.length;
      lines.add(
        MeasuredLine(
          start: lineStart,
          end: cursor,
          height: height,
          width: lineX,
          hardBreak: hardBreak,
          textTop: baseline - textAscent,
          segments: [
            for (final s in segments)
              MeasuredSegment(
                start: s.start,
                end: s.end,
                left:
                    s.left +
                    (s.ruby == null
                        ? 0
                        : math.max(0, s.ruby!.width - s.width) / 2),
                width: s.width,
                letterSpacing: s.letterSpacing,
                baseline: s.baseline,
                top: textAscent - s.baseline,
                ruby: s.ruby,
              ),
            for (final object in pending)
              if (object.textBox case final atom?)
                ...atom.place(
                  object.left,
                  object.topInLine(height, baseline) - (baseline - textAscent),
                ),
          ]..sort((a, b) => a.start.compareTo(b.start)),
        ),
      );
      for (final span in active) {
        if (rowBoxes[span] case final rect?) {
          boxPlacements.add(
            InlineBoxPlacement(
              span: span,
              box: boxes[span.id]!,
              line: lineIndex,
              rect: _inlineBorderRect(
                rect.shift(Offset(0, baseline)),
                height,
                atTop: topEdge && lineIndex == 0,
                atBottom: bottomEdge && cursor == text.length,
              ),
              first: span.first && span.start >= lineStart,
              last: span.last && span.end <= cursor,
            ),
          );
        }
      }
      for (final image in pending) {
        final left =
            image.left +
            (image.textBox == null && segments.isEmpty && align == null
                ? math.max(0, (width - lineX) / 2)
                : 0) +
            image.margin.left;
        final top = image.topInLine(height, baseline) + image.margin.top;
        final box = image.box;
        if (box != null) {
          boxPlacements.add(
            InlineBoxPlacement(
              span: InlineBoxSpan(
                start: image.offset,
                end: image.textBox?.end ?? image.offset,
                id: image.elementId,
                box: const [],
              ),
              box: box,
              line: lineIndex,
              first: true,
              last: true,
              rect: Rect.fromLTWH(
                left,
                top,
                image.size.width - image.margin.horizontal,
                image.size.height - image.margin.vertical,
              ),
            ),
          );
        }
        if (image.textBox case final atom?) {
          final origin = Offset(image.left, image.topInLine(height, baseline));
          boxPlacements.addAll(
            atom.boxes.map((b) => _shiftInlineBox(b, origin, lineIndex, 0)),
          );
          placements.addAll(
            atom.images.map(
              (im) => _shiftInlineImage(im, origin, lineIndex, 0),
            ),
          );
          continue;
        }
        placements.add(
          InlineImagePlacement(
            offset: image.offset,
            line: lineIndex,
            left: left + (box?.insetLeft ?? 0),
            top: top + (box?.insetTop ?? 0),
            size: image.content ?? image.size,
            resourcePath: image.resourcePath,
            alt: image.alt,
            imageFit: image.imageFit,
            noteLink: image.noteLink,
            altIsFootnote: image.altIsFootnote,
            formula: image.formula,
          ),
        );
      }
      total += height;
      lineStart = cursor;
      lineX = leadingFloat != null && total < leadingFloat.height - .1
          ? leadingFloat.width
          : 0;
      textHeight = 0;
      textAscent = 0;
      textDescent = 0;
      imageHeight = 0;
      hardBreak = false;
      hasContent = false;
      segments = <MeasuredSegment>[];
      pending = <_InlineSpec>[];
    }

    void appendRuby(
      RubyRange range,
      int from, {
      String? mark,
      bool under = false,
      Color? color,
    }) {
      final end = range.baseEnd - sourceOffset + prefixLength;
      final base = TextPainter(
        text: TextSpan(children: BlockMeasurer._slice(runs, styles, from, end)),
        textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
        textScaler: options.textScaler,
      )..layout();
      final metrics = base.computeLineMetrics().first;
      final labelStart = range.labelStart - sourceOffset + prefixLength;
      final labelEnd = range.labelEnd - sourceOffset + prefixLength;
      final annotation =
          BlockMeasurer._slice(runs, styles, labelStart, labelEnd).first
              as TextSpan;
      final baseStyle =
          (BlockMeasurer._slice(runs, styles, from, end).first as TextSpan)
              .style!;
      final fontSize = math.min(
        (baseStyle.fontSize ?? baseSize) * .55,
        annotation.style?.fontSize ?? baseSize,
      );
      final family = annotation.style?.fontFamily;
      final labelText = mark ?? text.substring(labelStart, labelEnd);
      final painter = RubyLabel.painter(
        labelText,
        fontSize,
        family,
        options.textScaler,
      );
      final label = RubyLabel(
        labelText,
        fontSize,
        family,
        painter.width,
        painter.height,
        color: color ?? annotation.style?.color,
        below: under,
      );
      final occupied = math.max(base.width, label.width);
      if (hasContent && lineX + occupied > width + .1) finishLine();
      segments.add(
        MeasuredSegment(
          start: from,
          end: end,
          left: lineX,
          width: base.width,
          baseline: metrics.baseline,
          ruby: label,
        ),
      );
      lineX += occupied;
      textHeight = math.max(textHeight, metrics.height);
      textAscent = math.max(textAscent, metrics.baseline);
      textDescent = math.max(textDescent, metrics.height - metrics.baseline);
      hasContent = true;
      cursor = range.end - sourceOffset + prefixLength;
      base.dispose();
      painter.dispose();
    }

    void appendText(int from, int to) {
      final closing = spans
          .where((s) => s.end == to && s.last)
          .fold(0.0, (n, s) => n + boxes[s.id]!.insetRight);
      final noWrap = nowrap.any((r) => r.$1 <= from && to <= r.$2);
      final bounded =
          !noWrap &&
          !rtl &&
          to - from > 128 &&
          !_inlineContextualText.hasMatch(text.substring(from, to));
      var lastWidth = -1.0, previousLength = 0;
      while (from < to) {
        final availableRaw = width - lineX - closing;
        if (availableRaw <= 0 && hasContent) {
          finishLine();
          continue;
        }
        final available = noWrap
            ? double.infinity
            : math.max(1.0, availableRaw);
        final window = _shapeInlineWindow(
          text: text,
          runs: runs,
          styles: styles,
          from: from,
          to: to,
          prefixLength: prefixLength,
          bounded: bounded,
          initialLength: available == lastWidth
              ? math.max(48, previousLength * 4)
              : 128,
          rtl: rtl,
          available: available,
        );
        final metrics = window.metrics;
        try {
          if (metrics.isEmpty ||
              hasContent &&
                  (metrics.first.width > availableRaw + .1 ||
                      softBreaks.contains(from) && metrics.length > 1)) {
            finishLine();
            continue;
          }
          final metric = metrics.first;
          final last = metrics.length == 1;
          final stop = last
              ? to
              : from +
                    window.display.sourceOffset(
                      _lineStartAt(window.painter, metrics, 1, 0),
                    );
          if (stop <= from) {
            finishLine();
            continue;
          }
          final measuredWidth = last && stop <= prefixLength
              ? window.painter.width
              : metric.width;
          segments.add(
            MeasuredSegment(
              start: from,
              end: stop,
              left: lineX,
              width: measuredWidth,
              baseline: metric.baseline,
            ),
          );
          lineX += measuredWidth;
          textHeight = math.max(textHeight, metric.height);
          textAscent = math.max(textAscent, metric.baseline);
          textDescent = math.max(textDescent, metric.height - metric.baseline);
          hasContent = true;
          // 同宽续行借用上一行的字数决定预量范围。每行仍从真实行首取字宽：
          // 小数字号的字体从整段取宽会积累浮点误差，进而改变行末字距。
          lastWidth = available;
          previousLength = stop - from;
          cursor = from = stop;
          if (!last) finishLine();
        } finally {
          window.painter.dispose();
        }
      }
    }

    /// 换行符是唯一的「硬换行」规则入口。
    ///
    /// 规则固定，文字测量和事件循环不再各自判断：
    /// 1. 行首的换行（块的最前面）直接跳过，不产生空行；
    /// 2. 行尾的换行（块的最后一个字符）只结束当前行，不再补空行；
    /// 3. 没有可见内容时只把行首推过去，不制造空行。
    ///
    /// 连续 br 的额外行高从可见来源元素取得，不再消耗正文字符。
    void consumeNewline(int offset) {
      cursor = offset + 1;
      if (hasContent) {
        hardBreak = true;
        finishLine();
      } else {
        lineStart = cursor;
      }
    }

    // 换行符、强制边界、行内图片和行内盒子的起止都是「断行事件」，统一按
    // 偏移排序处理；换行符不再是 appendText 内部的第二套规则。
    final newlines = <int>[
      for (var i = 0; i < text.length; i++)
        if (text[i] == '\n') i,
    ];
    final rubyAt = {
      for (final range in ruby)
        range.start - sourceOffset + prefixLength: range,
    };
    final events = <int>{
      ...marks.keys,
      ...softBreaks,
      for (final r in nowrap) ...[r.$1, r.$2],
      ...rubyAt.keys,
      for (final f in formulas) ...[f.offset, f.formula!.end],
      ...newlines,
      ...textGaps.keys,
      for (final (a, b) in hiddenRanges) ...[a, b],
      ...images.map((i) => i.offset),
      for (final atom in atoms) atom.textBox!.end,
      ...forcedBreaks,
      ...blanks.keys,
      for (final span in spans) ...[span.start, span.end],
    }.toList()..sort();
    for (final offset in columns == null ? events : const <int>[]) {
      if (offset < cursor) continue;
      if (offset > cursor) {
        if (hiddenRanges.any((r) => r.$1 <= cursor && offset <= r.$2) ||
            formulas.any(
              (f) => f.offset <= cursor && offset <= f.formula!.end,
            )) {
          // 只跳过绘制范围，行的原文起止仍跨过注释，定位坐标不压缩。
          cursor = offset;
        } else {
          appendText(cursor, offset);
        }
      }
      // 备用编码内部可能也有换行和标签；这些事件同样不能改变公式的显示。
      if (hiddenRanges.any((r) => r.$1 <= offset && offset < r.$2) &&
          !formulas.any((f) => f.offset == offset)) {
        continue;
      }
      if (formulas.any((f) => f.offset < offset && offset < f.formula!.end)) {
        continue;
      }
      // 先结算在这一行结束的行内盒子右边距：它属于正在结束的这一行，
      // 必须在断行之前加进 lineX，否则绘制会把右边距算到下一行。
      for (final span in spans.where((s) => s.end == offset && s.last)) {
        lineX += boxes[span.id]!.insetRight;
      }
      final newlineHere = offset < text.length && text[offset] == '\n';
      final imageBreakHere = images.any(
        (image) => image.offset == offset && image.breakAfter,
      );
      if (newlineHere && !imageBreakHere) {
        // 换行符本身不画；行尾算在上一行里，行首不会以它开头。
        consumeNewline(offset);
      } else if (forcedBreaks.contains(offset) && hasContent) {
        // 强制边界和换行符落在同一位置时，上面已经断过一次，这里不能再断，
        // 否则会多出一个空行、行高却只算一行。
        hardBreak = true;
        finishLine();
      }
      if (blanks[offset] case final heights?) {
        for (final height in heights) {
          lines.add(
            MeasuredLine(
              start: cursor,
              end: cursor,
              height: height,
              width: 0,
              hardBreak: true,
            ),
          );
          total += height;
        }
      }
      if (textGaps[offset] case final gap?) {
        if (hasContent) {
          if (lineX + gap.width + baseSize <= width) {
            if (gap.includesSpace) {
              segments.add(
                MeasuredSegment(
                  start: offset,
                  end: offset + 1,
                  left: lineX,
                  width: gap.width,
                  baseline: textAscent,
                ),
              );
            }
            lineX += gap.width;
          } else {
            finishLine();
          }
        }
        if (gap.includesSpace) cursor = offset + 1;
      }
      for (final span in spans.where((s) => s.start == offset && s.first)) {
        final pad = boxes[span.id]!.insetLeft;
        if (hasContent && lineX + pad + baseSize > width) finishLine();
        lineX += pad;
      }
      for (final image in images.where((i) => i.offset == offset)) {
        if (image.blockDisplay && hasContent) {
          hardBreak = true;
          finishLine();
        }
        if (hasContent && lineX + image.size.width > width + 0.1) finishLine();
        pending.add(image.at(lineX));
        lineX += image.size.width;
        imageHeight = math.max(imageHeight, image.size.height);
        hasContent = true;
        if (image.formula != null) cursor = image.formula!.end;
        if (image.textBox case final atom?) cursor = atom.end;
        if (image.blockDisplay || image.breakAfter) {
          if (image.blockDisplay && image.formula == null) {
            textHeight = image.size.height;
          }
          if (newlineHere && image.breakAfter) {
            consumeNewline(offset);
          } else {
            hardBreak = true;
            finishLine();
          }
        }
      }
      if (rubyAt[offset] case final range?) {
        appendRuby(range, offset);
      } else if (marks[offset] case final mark?) {
        final start = offset + sourceOffset - prefixLength,
            end = mark.end + sourceOffset - prefixLength;
        appendRuby(
          (
            start: start,
            baseEnd: end,
            end: end,
            labelStart: start,
            labelEnd: end,
          ),
          offset,
          mark: mark.text,
          under: mark.below,
          color: mark.color,
        );
      }
    }
    if (columns != null) {
      lines.add(columns);
      total = columns.height;
    } else {
      if (cursor < text.length) appendText(cursor, text.length);
      finishLine();
    }

    if (leadingFloat != null && lines.isNotEmpty) {
      total += _stackFloatLines(lines, leadingFloat);
    }

    // 隐藏内容可以让可见父段落没有文本行；只有正常文字丢失测量时才补一行。
    if (lines.isEmpty && hiddenRanges.isEmpty) {
      lines.add(
        MeasuredLine(
          start: 0,
          end: text.length,
          height: fallbackHeight,
          width: 0,
        ),
      );
      total += fallbackHeight;
    }

    return MeasuredBlock(
      blockId: block.id,
      kind: block.kind,
      level: block.level,
      text: text,
      runs: runs,
      runStyles: styles,
      lines: List.unmodifiable(lines),
      height:
          total +
          (box?.insetTop ?? 0) +
          (box?.insetBottom ?? 0) +
          bodyTopOverride +
          bodyBottomOverride,
      inset: inset,
      layoutWidth: width,
      displayPrefixLength: prefixLength,
      align: align,
      marker: marker,
      markerInset: markerInset,
      // 分段的正文已在测量时摊开字距；绘制不能再把整行拉伸一次。
      justify: false,
      hasScript: runs.any((run) => run.isScript),
      box: box,
      boxId: block.boxId,
      containerBoxes: containerBoxes,
      // 水平外边距与祖先偏移不是盒子内的列表缩进，绘制时不能再扣掉。
      boxIndent: boxIndent,
      bodyTop: (box?.insetTop ?? 0) + bodyTopOverride,
      bodyBottom: (box?.insetBottom ?? 0) + bodyBottomOverride,
      marginTop: marginTop,
      marginBottom: marginBottom,
      textStyle: BlockTextStyle(shadows: textShadow, rtl: rtl),
      inlineImages: List.unmodifiable(placements),
      inlineBoxes: List.unmodifiable(boxPlacements),
    );
  }
}
