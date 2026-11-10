part of 'block_measure.dart';

extension _DisplayTextMeasurement on BlockMeasurer {
  /// 一个持久正文块可以包含多个块级显示范围。各范围按同一容器约束测量，
  /// 再合成一个测量块；文字、链接、UTF-16 偏移及分页定位仍然只有原来一份。
  MeasuredBlock _measureDisplayText(
    ContentBlock block, {
    required bool withIndent,
    int? styleLevel,
    required int sourceOffset,
  }) {
    final index = displayTree!.blockIndexById[block.id]!;
    final end = sourceOffset + block.runLength;
    final cuts = <int>{
      sourceOffset,
      end,
      for (final node
          in displayTree!.inlineEmpty[index] ?? const <DisplayNode>[])
        if (node.element.anchorOffset > sourceOffset &&
            node.element.anchorOffset < end)
          node.element.anchorOffset,
      for (final node in displayTree!.flows[index] ?? const <DisplayNode>[])
        for (final r in node.element.ranges)
          if (r.block == index) ...[
            r.start.clamp(sourceOffset, end),
            r.end.clamp(sourceOffset, end),
          ],
    }.toList()..sort();
    final parts = <MeasuredBlock>[];
    for (var i = 0; i + 1 < cuts.length; i++) {
      final from = cuts[i] - sourceOffset, to = cuts[i + 1] - sourceOffset;
      if (to <= from) continue;
      for (final node
          in displayTree!.inlineEmpty[index] ?? const <DisplayNode>[]) {
        if (node.element.anchorOffset == cuts[i]) {
          parts.add(_measureEmptyNode(node, index));
        }
      }
      parts.add(
        _measureText(
          _displaySlice(block, from, to),
          withIndent: withIndent && from == 0,
          styleLevel: styleLevel,
          sourceOffset: cuts[i],
          flowPart: true,
        ),
      );
    }
    final runs = <TextRun>[], styles = <TextStyle>[];
    final lines = <MeasuredLine>[];
    final images = <InlineImagePlacement>[];
    final boxes = <InlineBoxPlacement>[];
    final frames = <ContainerBoxFrame>[];
    var cursor = 0, height = 0.0;
    for (final part in parts) {
      final lineBase = lines.length;
      if (part.isDecoration && part.height > 0) {
        // 空盒子有显示高度，没有正文字符；零长度行保持所有原文偏移连续。
        lines.add(
          MeasuredLine(
            start: cursor,
            end: cursor,
            height: part.height,
            width: 0,
          ),
        );
      }
      for (var i = 0; i < part.lines.length; i++) {
        final line = part.lines[i];
        final left = part.inset + part.horizontalOffset(i, part.layoutWidth!);
        final segments = line.segments.isNotEmpty
            ? line.segments
            : [
                MeasuredSegment(
                  start: line.start,
                  end: line.end,
                  left: 0,
                  width: line.width,
                  letterSpacing: part.justifySpacingFor(
                    i,
                    maxWidth: part.layoutWidth!,
                    enabled: part.justifiesLine(i),
                    textScaler: options.textScaler,
                  ),
                ),
              ];
        final top = i == 0 ? part.bodyTop : 0.0;
        final bottom = i == part.lines.length - 1 ? part.bodyBottom : 0.0;
        lines.add(
          MeasuredLine(
            start: cursor + line.start,
            end: cursor + line.end,
            height: line.height + top + bottom,
            width: line.width,
            hardBreak: line.hardBreak || i == part.lines.length - 1,
            hyphenated: line.hyphenated,
            textTop: line.textTop + top,
            segments: [
              for (final s in segments)
                MeasuredSegment(
                  start: cursor + s.start,
                  end: cursor + s.end,
                  left: left + s.left,
                  width: s.width,
                  letterSpacing: s.letterSpacing,
                  top: s.top,
                  baseline: s.baseline,
                ),
            ],
          ),
        );
      }
      for (final image in part.inlineImages) {
        images.add(
          InlineImagePlacement(
            offset: cursor + image.offset,
            line: lineBase + image.line,
            left:
                part.inset +
                part.horizontalOffset(image.line, part.layoutWidth!) +
                image.left,
            top: image.top + (image.line == 0 ? part.bodyTop : 0),
            size: image.size,
            resourcePath: image.resourcePath,
            alt: image.alt,
            formula: image.formula?.shifted(cursor),
          ),
        );
      }
      for (final b in part.inlineBoxes) {
        boxes.add(
          InlineBoxPlacement(
            span: InlineBoxSpan(
              start: cursor + b.span.start,
              end: cursor + b.span.end,
              id: b.span.id,
              box: b.span.box,
              scale: b.span.scale,
              styleId: b.span.styleId,
              first: b.span.first,
              last: b.span.last,
            ),
            box: b.box,
            line: lineBase + b.line,
            rect: b.rect.shift(
              Offset(
                part.inset + part.horizontalOffset(b.line, part.layoutWidth!),
                b.line == 0 ? part.bodyTop : 0,
              ),
            ),
            first: b.first,
            last: b.last,
          ),
        );
      }
      for (final f in part.containerBoxes) {
        frames.add(
          ContainerBoxFrame(
            elementId: f.elementId,
            box: f.box,
            first: f.first,
            last: f.last,
            left: f.left,
            width: f.width,
            top: f.top,
            bottom: f.bottom,
            lineFrom: lineBase,
            lineTo: lines.length,
          ),
        );
      }
      runs.addAll(part.runs);
      styles.addAll(part.runStyles);
      cursor += part.text.length;
      height += part.height;
    }
    final first = parts.first;
    return MeasuredBlock(
      blockId: block.id,
      kind: block.kind,
      level: block.level,
      text: parts.map((p) => p.text).join(),
      runs: runs,
      runStyles: styles,
      lines: lines,
      height: height,
      layoutWidth: options.contentWidth,
      displayPrefixLength: first.displayPrefixLength,
      hasScript: parts.any((part) => part.hasScript),
      marker: first.marker,
      markerInset: first.markerInset,
      containerBoxes: frames,
      inlineImages: images,
      inlineBoxes: boxes,
    );
  }

  ContentBlock _displaySlice(ContentBlock block, int from, int to) {
    var offset = 0;
    final runs = <TextRun>[];
    for (final run in block.runs) {
      final end = offset + run.text.length;
      if (end > from && offset < to) {
        runs.add(
          TextRun(
            run.text.substring(
              math.max(0, from - offset),
              math.min(run.text.length, to - offset),
            ),
            styleId: run.styleId,
            link: run.link,
            footnote: run.footnote,
          ),
        );
      }
      offset = end;
    }
    return ContentBlock(
      id: block.id,
      kind: block.kind,
      level: block.level,
      runs: runs,
      styleId: block.styleId,
      nest: block.nest,
      ordered: block.ordered,
      ordinal: block.ordinal,
      isQuoteContainer: block.isQuoteContainer,
      boxId: block.boxId,
      parentBox: block.parentBox,
      breaks: [
        for (final p in block.breaks)
          if (p >= from && p < to) p - from,
      ],
      inlineImages: [
        for (final image in block.inlineImages)
          if (image.offset >= from &&
              (image.offset < to || to == block.runLength))
            InlineImage(
              offset: image.offset - from,
              resourcePath: image.resourcePath,
              width: image.width,
              height: image.height,
              alt: image.alt,
              imageWidth: image.imageWidth,
              imageMaxWidth: image.imageMaxWidth,
              styleId: image.styleId,
            ),
      ],
      inlineBoxes: [
        for (final s in block.inlineBoxes)
          if (s.start < to && s.end > from)
            InlineBoxSpan(
              start: math.max(s.start, from) - from,
              end: math.min(s.end, to) - from,
              id: s.id,
              box: s.box,
              scale: s.scale,
              styleId: s.styleId,
              first: s.first && s.start >= from,
              last: s.last && s.end <= to,
            ),
      ],
    );
  }
}
