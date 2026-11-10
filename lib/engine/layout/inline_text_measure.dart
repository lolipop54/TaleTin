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
    Set<int> forcedBreaks = const {},
    List<(int, int)> hiddenRanges = const [],
    List<ContainerBoxFrame> containerBoxes = const [],
    double bodyTopOverride = 0,
    double bodyBottomOverride = 0,
    int sourceOffset = 0,
  }) {
    final blockIndex = displayTree?.blockIndexById[block.id];
    final sourceElements = displayTree?.source?.elements;
    bool breakAfterImage(int imageIndex) {
      if (blockIndex == null || sourceElements == null) return false;
      final offset = block.inlineImages[imageIndex].offset;
      final candidates = sourceElements
          .where(
            (e) =>
                e.role == 'image' &&
                e.ranges.any(
                  (r) =>
                      r.block == blockIndex && r.start == offset + sourceOffset,
                ),
          )
          .toList();
      final occurrence = block.inlineImages
          .take(imageIndex)
          .where((image) => image.offset == offset)
          .length;
      if (occurrence >= candidates.length) return false;
      final image = candidates[occurrence];
      final next = occurrence + 1 < candidates.length
          ? candidates[occurrence + 1].nodeId
          : null;
      // 图片后的br可能没有保留文字占位，但来源树仍保存它的位置和DOM顺序。
      // 只恢复显示断行，不插入正文字符，也不改变章节长度或Locator。
      return sourceElements.any(
        (e) =>
            e.tag == 'br' &&
            e.anchor == blockIndex &&
            e.anchorOffset == offset + sourceOffset &&
            e.nodeId > image.nodeId &&
            (next == null || e.nodeId < next),
      );
    }

    final images = <_InlineSpec>[
      ...formulas,
      for (final (index, image) in block.inlineImages.indexed)
        _InlineSpec(
          offset: (image.offset + prefixLength).clamp(0, text.length),
          size: _inlineImageSize(image, width),
          resourcePath: image.resourcePath,
          alt: image.alt,
          breakAfter: breakAfterImage(index),
          blockDisplay:
              image.styleId != null &&
              styleTable?[image.styleId!].block.display == DisplaySpec.block,
        ),
    ]..sort((a, b) => a.offset.compareTo(b.offset));

    final spans = [
      for (final span in block.inlineBoxes)
        InlineBoxSpan(
          start: span.start + prefixLength,
          end: span.end + prefixLength,
          id: span.id,
          box: span.box,
          scale: span.scale,
          styleId: span.styleId,
          first: span.first,
          last: span.last,
        ),
    ];
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
    final fallbackHeight = _lineHeightOf(styles.isEmpty ? null : styles.first);
    final lines = <MeasuredLine>[];
    final placements = <InlineImagePlacement>[];
    var total = 0.0;

    // 当前行状态
    var lineStart = 0;
    var cursor = 0;
    var lineX = 0.0;
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
      if (options.justifies(block.kind, align) &&
          !hardBreak &&
          cursor < text.length) {
        final gains = <double>[];
        for (final segment in segments) {
          double widthAt(double spacing) {
            final painter = EdgeAlignedTextPainter(
              text: TextSpan(
                children: BlockMeasurer._slice(
                  runs,
                  styles,
                  segment.start,
                  segment.end,
                  fixedPrefixLength: prefixLength,
                  letterSpacing: spacing,
                ),
              ),
              textScaler: options.textScaler,
              spacing: spacing,
              fixedPrefixLength: (prefixLength - segment.start).clamp(
                0,
                segment.end - segment.start,
              ),
            )..layout();
            final result = painter.width;
            painter.dispose();
            return result;
          }

          gains.add(math.max(0, widthAt(1) - widthAt(0)));
        }
        // 缩进独立成段时，其后也不能再补一份两端对齐字距。
        final gaps = [
          for (var i = 0; i < segments.length; i++)
            i + 1 < segments.length && segments[i].end > prefixLength
                ? 1.0
                : 0.0,
        ];
        final gain =
            gains.fold<double>(0, (n, v) => n + v) +
            gaps.fold<double>(0, (n, v) => n + v);
        final spacing = gain > 0 ? math.max(0.0, width - lineX) / gain : 0.0;
        pending = [
          for (final image in pending)
            _InlineSpec(
              offset: image.offset,
              size: image.size,
              resourcePath: image.resourcePath,
              alt: image.alt,
              formula: image.formula,
              blockDisplay: image.blockDisplay,
              breakAfter: image.breakAfter,
              left:
                  image.left +
                  [
                    for (var i = 0; i < segments.length; i++)
                      if (segments[i].end <= image.offset)
                        (gains[i] + gaps[i]) * spacing,
                  ].fold(0.0, (a, b) => a + b),
            ),
        ];
        var shift = 0.0;
        segments = [
          for (var i = 0; i < segments.length; i++)
            (() {
              final old = segments[i];
              final next = MeasuredSegment(
                start: old.start,
                end: old.end,
                left: old.left + shift,
                width: old.width + gains[i] * spacing,
                letterSpacing: spacing,
                baseline: old.baseline,
                top: old.top,
              );
              shift += (gains[i] + gaps[i]) * spacing;
              return next;
            })(),
        ];
        lineX += shift;
      }
      final contentHeight = textHeight > 0
          ? math.max(textHeight, textAscent + textDescent)
          : fallbackHeight;
      final active = spans
          .where((s) => s.start < cursor && s.end > lineStart)
          .toList();
      var above = textAscent;
      var below = textHeight > 0 ? contentHeight - textAscent : 0.0;
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
          textDirection: TextDirection.ltr,
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
      var hasFormula = false;
      for (final image in pending) {
        if (image.formula case final formula?) {
          hasFormula = true;
          above = math.max(above, formula.baseline);
          below = math.max(below, image.size.height - formula.baseline);
        }
      }
      // 只有图片的一行保留最低行高，独立公式则使用自己的高度和基线。
      final lineContent = hasFormula
          ? above + below
          : math.max(contentHeight, above + below);
      final height = math.max(lineContent, imageHeight);
      final baseline = hasFormula ? above : above + (height - lineContent) / 2;
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
                left: s.left,
                width: s.width,
                letterSpacing: s.letterSpacing,
                baseline: s.baseline,
                top: textAscent - s.baseline,
              ),
          ],
        ),
      );
      for (final span in active) {
        if (rowBoxes[span] case final rect?) {
          boxPlacements.add(
            InlineBoxPlacement(
              span: span,
              box: boxes[span.id]!,
              line: lineIndex,
              rect: rect.shift(Offset(0, baseline)),
              first: span.first && span.start >= lineStart,
              last: span.last && span.end <= cursor,
            ),
          );
        }
      }
      for (final image in pending) {
        placements.add(
          InlineImagePlacement(
            offset: image.offset,
            line: lineIndex,
            // 图片独占一行时默认居中；行内小图继续跟随文字，不改变行内顺序。
            left:
                image.left +
                (segments.isEmpty && align == null
                    ? math.max(0, (width - lineX) / 2)
                    : 0),
            top: image.formula == null
                ? (height - image.size.height) / 2
                : baseline - image.formula!.baseline,
            size: image.size,
            resourcePath: image.resourcePath,
            alt: image.alt,
            formula: image.formula,
          ),
        );
      }
      total += height;
      lineStart = cursor;
      lineX = 0;
      textHeight = 0;
      textAscent = 0;
      textDescent = 0;
      imageHeight = 0;
      hardBreak = false;
      hasContent = false;
      segments = <MeasuredSegment>[];
      pending = <_InlineSpec>[];
    }

    void appendText(int from, int to) {
      while (from < to) {
        // 换行符不在这个范围里：它们由事件循环统一处理，避免这里再判断一遍
        // 行首／行尾和强制断行，两个地方各断一次。
        final closing = spans
            .where((s) => s.end == to && s.last)
            .fold(0.0, (n, s) => n + boxes[s.id]!.insetRight);
        final availableRaw = width - lineX - closing;
        if (availableRaw <= 0 && hasContent) {
          finishLine();
          continue;
        }
        final available = math.max(1.0, availableRaw);
        // 带背景或边框的行内文字也允许在数字连字符后换行。断点只用于
        // 测量，返回的分段边界立即换回原文坐标，不能混入选文或听书。
        final source = text.substring(from, to);
        final prefixEnd = (prefixLength - from).clamp(0, source.length);
        final display = ProseLineBreaks.display(
          FixedIndent.display(source.substring(0, prefixEnd)) +
              source.substring(prefixEnd),
          hyphenate: false,
        );
        var displayCursor = 0;
        final displaySpans = BlockMeasurer._slice(
          runs,
          styles,
          from,
          to,
          fixedPrefixLength: prefixLength,
        ).cast<TextSpan>();
        final painter = TextPainter(
          text: TextSpan(
            children: [
              for (final span in displaySpans)
                TextSpan(
                  text: display.text.substring(
                    display.displayOffset(displayCursor),
                    display.displayOffset(displayCursor += span.text!.length),
                  ),
                  style: span.style,
                ),
            ],
          ),
          textDirection: TextDirection.ltr,
          textScaler: options.textScaler,
        )..layout(maxWidth: available);
        _fitHyphenLines(
          painter,
          display,
          [for (final span in displaySpans) TextRun(span.text!)],
          [for (final span in displaySpans) span.style!],
          available,
        );
        final metrics = painter.computeLineMetrics();
        if (metrics.isEmpty) {
          painter.dispose();
          finishLine();
          continue;
        }
        // TextPainter 在余宽不足一个字时仍会强制排出首字，行宽可能比
        // maxWidth 大。分段混排必须先换到下一行再放，不能只看返回几行。
        // 公式、代码盒子、样式切分后的普通文字都使用这一处余宽判定。
        if (hasContent && metrics.first.width > availableRaw + .1) {
          painter.dispose();
          finishLine();
          continue;
        }
        if (metrics.length == 1) {
          // EM SPACE独立成段时，行指标会排除行尾空白；缩进必须计入完整宽度。
          final measuredWidth = to <= prefixLength
              ? painter.width
              : metrics.first.width;
          segments.add(
            MeasuredSegment(
              start: from,
              end: to,
              left: lineX,
              width: measuredWidth,
              baseline: metrics.first.baseline,
            ),
          );
          lineX += measuredWidth;
          textHeight = math.max(textHeight, metrics.first.height);
          textAscent = math.max(textAscent, metrics.first.baseline);
          textDescent = math.max(
            textDescent,
            metrics.first.height - metrics.first.baseline,
          );
          hasContent = true;
          from = to;
          cursor = from;
          painter.dispose();
        } else {
          final firstEnd = _lineStartAt(painter, metrics, 1, 0);
          final stop =
              from + math.min<int>(display.sourceOffset(firstEnd), to - from);
          painter.dispose();
          if (stop <= from) {
            // 一个字都放不下：结束当前行，用整行宽重新试
            finishLine();
            continue;
          }
          segments.add(
            MeasuredSegment(
              start: from,
              end: stop,
              left: lineX,
              width: metrics.first.width,
              baseline: metrics.first.baseline,
            ),
          );
          lineX += metrics.first.width;
          textHeight = math.max(textHeight, metrics.first.height);
          textAscent = math.max(textAscent, metrics.first.baseline);
          textDescent = math.max(
            textDescent,
            metrics.first.height - metrics.first.baseline,
          );
          hasContent = true;
          from = stop;
          cursor = from;
          finishLine();
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
    /// 连续 `<br>` 在正文转换阶段已经合并成一个换行（Rust 的 `html_text.rs`
    /// 明确丢掉连续的换行 run），所以这里不需要再补空白行。
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
    final events = <int>{
      for (final f in formulas) ...[f.offset, f.formula!.end],
      ...newlines,
      for (final (a, b) in hiddenRanges) ...[a, b],
      ...images.map((i) => i.offset),
      ...forcedBreaks,
      for (final span in spans) ...[span.start, span.end],
    }.toList()..sort();
    for (final offset in events) {
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
        pending.add(
          _InlineSpec(
            offset: image.offset,
            size: image.size,
            resourcePath: image.resourcePath,
            alt: image.alt,
            left: lineX,
            formula: image.formula,
          ),
        );
        lineX += image.size.width;
        imageHeight = math.max(imageHeight, image.size.height);
        hasContent = true;
        if (image.formula != null) cursor = image.formula!.end;
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
    }
    if (cursor < text.length) appendText(cursor, text.length);
    finishLine();

    // 防御：文字非空却没有测出任何行时，至少留一行，不能出现空块。
    if (lines.isEmpty) {
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
      textStyle: BlockTextStyle(shadows: textShadow),
      inlineImages: List.unmodifiable(placements),
      inlineBoxes: List.unmodifiable(boxPlacements),
    );
  }

  /// 行内图片的显示尺寸：优先实际像素，再应用书里的 width／max-width，
  /// 最后保证不超过正文宽度和一页高度。
  Size _inlineImageSize(InlineImage image, double maxWidth) {
    final rawWidth = (image.width ?? 0).toDouble();
    final rawHeight = (image.height ?? 0).toDouble();
    final em = options.settings.fontSize.toDouble();
    // 尺寸嗅探失败时按一个字大小兜底，至少能看见占位
    var width = rawWidth > 0 ? rawWidth : em;
    var height = rawHeight > 0 ? rawHeight : width;
    final computed = image.styleId == null ? null : styleTable?[image.styleId!];
    double? sizeOf(Length? value) => value == null || value.isAuto
        ? null
        : value.resolve(_lengthContext(computed!, maxWidth));
    final explicit = computed == null
        ? _imageLength(image.imageWidth, maxWidth)
        : sizeOf(computed.size.width);
    if (explicit != null && explicit > 0) {
      final ratio = rawWidth > 0 ? explicit / rawWidth : 1.0;
      width = explicit;
      height = rawHeight > 0 ? rawHeight * ratio : explicit;
    }
    final cap = computed == null
        ? _imageLength(image.imageMaxWidth, maxWidth)
        : sizeOf(computed.size.maxWidth);
    if (cap != null && cap > 0 && width > cap) {
      final ratio = cap / width;
      width = cap;
      height *= ratio;
    }
    var scale = math.min(1.0, maxWidth / width);
    if (height * scale > options.contentHeight) {
      scale = math.min(scale, options.contentHeight / height);
    }
    return Size(width * scale, height * scale);
  }

  /// 一行基准高度（图片单独占一行时用它作为最小行高）。
  double _lineHeightOf(TextStyle? style) {
    if (style == null) {
      return options.settings.fontSize * options.settings.lineHeight;
    }
    final painter = TextPainter(
      text: TextSpan(text: '国', style: style),
      textDirection: TextDirection.ltr,
      textScaler: options.textScaler,
    )..layout();
    final height = painter.height;
    painter.dispose();
    return height;
  }
}

/// 测量用的行内图片：块内位置与已换算好的显示尺寸。
class _InlineSpec {
  _InlineSpec({
    required this.offset,
    required this.size,
    required this.resourcePath,
    this.alt,
    this.left = 0,
    this.blockDisplay = false,
    this.breakAfter = false,
    this.formula,
  });

  final int offset;
  final bool blockDisplay;
  final bool breakAfter;
  final Size size;
  final String resourcePath;
  final String? alt;
  final FormulaGeometry? formula;

  /// 在这一行里的横向起点（测量过程中填入）。
  final double left;
}
