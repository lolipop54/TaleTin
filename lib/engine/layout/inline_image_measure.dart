part of 'block_measure.dart';

extension _InlineImageMeasurement on BlockMeasurer {
  List<_InlineSpec> _paragraphImages(
    ContentBlock block,
    double contentWidth,
    double? parentHeight,
    int sourceOffset,
    int prefixLength,
    int textLength,
    TextStyle? font,
  ) {
    if (block.inlineImages.isEmpty) return const [];
    final blockIndex = displayTree?.blockIndexById[block.id];
    final sourceElements = displayTree?.source?.elements;
    (DisplayElement, int?)? sourceOfImage(int imageIndex) {
      if (blockIndex == null || sourceElements == null) return null;
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
      if (occurrence >= candidates.length) return null;
      final next = occurrence + 1 < candidates.length
          ? candidates[occurrence + 1].nodeId
          : null;
      return (candidates[occurrence], next);
    }

    final imageSources = [
      for (var i = 0; i < block.inlineImages.length; i++) sourceOfImage(i),
    ];
    bool breakAfterImage(int imageIndex) {
      final source = imageSources[imageIndex];
      if (source == null) return false;
      final (image, next) = source;
      final offset = block.inlineImages[imageIndex].offset + sourceOffset;
      // 图片后的br可能没有保留文字占位，但来源树仍保存它的位置和DOM顺序。
      // 只恢复显示断行，不插入正文字符，也不改变章节长度或Locator。
      return sourceElements!.any(
        (e) =>
            e.tag == 'br' &&
            e.anchor == blockIndex &&
            e.anchorOffset == offset &&
            displayTree?.hiddenElements.contains(e.id) != true &&
            e.nodeId > image.nodeId &&
            (next == null || e.nodeId < next),
      );
    }

    _InlineSpec measure(int index, double width, double? height, int offset) =>
        _measureInlineImage(
          block.inlineImages[index],
          width,
          offset: offset,
          elementId: imageSources[index]?.$1.id ?? -1 - index,
          breakAfter: breakAfterImage(index),
          parentHeight: height,
          fallbackStyle: font,
        );
    final result = <_InlineSpec>[];
    for (var i = 0; i < block.inlineImages.length; i++) {
      final id = imageSources[i]?.$1.id;
      if (displayTree?.hiddenElements.contains(id) == true) continue;
      final offset = (block.inlineImages[i].offset + prefixLength).clamp(
        0,
        textLength,
      );
      final wrapper = displayTree?.imageWrappers[id];
      if (wrapper == null) {
        result.add(measure(i, contentWidth, parentHeight, offset));
        continue;
      }
      final first = i;
      while (i + 1 < imageSources.length &&
          displayTree!.imageWrappers[imageSources[i + 1]?.$1.id] == wrapper) {
        i++;
      }
      result.add(
        _measureImageWrapper(
          wrapper,
          block,
          offset,
          contentWidth,
          parentHeight,
          (width, height) => [
            for (var j = first; j <= i; j++) measure(j, width, height, 0),
          ],
        ),
      );
    }
    return result;
  }

  String? _imageAlignment(InlineImage image) {
    if (displayTree?.authoritative != true) return null;
    final align = styleTable?[image.styleId ?? 0].text.verticalAlign;
    return align is VerticalAlignKeyword ? align.keyword : 'baseline';
  }

  /// 只指定一个边时，按源图比例推算另一边；百分比高度缺少确定的包含块高度。
  _InlineSpec _measureInlineImage(
    InlineImage image,
    double maxWidth, {
    required int offset,
    required int elementId,
    required bool breakAfter,
    required double? parentHeight,
    TextStyle? fallbackStyle,
  }) {
    final em = options.textScaler.scale(
      fallbackStyle?.fontSize ?? options.settings.fontSize.toDouble(),
    );
    final intrinsicWidth = (image.width ?? 0) > 0
        ? image.width!.toDouble()
        : em;
    final intrinsicHeight = (image.height ?? 0) > 0
        ? image.height!.toDouble()
        : intrinsicWidth;
    var intrinsic = Size(intrinsicWidth, intrinsicHeight);
    final computed = styleTable?[image.styleId ?? 0] ?? ComputedStyle.empty;
    final lengths = _lengthContext(computed, maxWidth);
    final box = resolveBlockBox(computed.box, lengths);
    final margins = computed.block.margin?.resolve(lengths);
    final margin = EdgeInsets.fromLTRB(
      margins?.left ?? 0,
      margins?.top ?? 0,
      margins?.right ?? 0,
      margins?.bottom ?? 0,
    );
    final horizontal = (box?.insetLeft ?? 0) + (box?.insetRight ?? 0);
    final vertical = (box?.insetTop ?? 0) + (box?.insetBottom ?? 0);
    final legacyWidth = image.styleId == null
        ? _imageLength(image.imageWidth, maxWidth)
        : null;
    final legacyMax = image.styleId == null
        ? _imageLength(image.imageMaxWidth, maxWidth)
        : null;
    final sizes = BoxSizeResolver(
      lengths,
      computed.size,
      box,
      parentHeight: parentHeight,
    );
    if (image.noteLink != null &&
        sizes.width.definite == null &&
        sizes.height.definite == null &&
        legacyWidth == null) {
      intrinsic *= em / intrinsic.height;
    }
    if (legacyWidth != null && legacyWidth > 0) {
      intrinsic *= legacyWidth / intrinsic.width;
    }
    var content = sizes.image(intrinsic);
    if (legacyMax != null && legacyMax > 0 && content.width > legacyMax) {
      content *= legacyMax / content.width;
    }
    // 行宽与行高按外边界占位；绘制、命中使用去掉边框和内边距的图片矩形。
    final capWidth = math.max(0.0, maxWidth - horizontal - margin.horizontal);
    final capHeight = math.max(
      0.0,
      options.contentHeight - vertical - margin.vertical,
    );
    var scale = 1.0;
    if (content.width > capWidth) scale = capWidth / content.width;
    if (content.height * scale > capHeight) scale = capHeight / content.height;
    content *= scale;
    final alignment = _imageAlignment(image);
    return _InlineSpec(
      offset: offset,
      size: Size(
        content.width + horizontal + margin.horizontal,
        content.height + vertical + margin.vertical,
      ),
      content: content,
      imageFit: BookImageFit.of(
        computed.size.objectFit,
        intrinsicWidth,
        intrinsicHeight,
      ),
      box: box,
      margin: margin,
      elementId: elementId,
      resourcePath: image.resourcePath,
      alt: image.alt,
      noteLink: image.noteLink,
      altIsFootnote: image.altIsFootnote,
      verticalAlign: alignment == 'legacy-center' ? 'baseline' : alignment,
      baselineLift: alignment == 'legacy-center'
          ? -(content.height + vertical + margin.vertical) / 2
          : _inlineBaselineLift(
              computed,
              lengths,
              () => _lineStrut(fallbackStyle).height,
            ),
      breakAfter: breakAfter,
      blockDisplay: computed.block.display == DisplaySpec.block,
    );
  }

  /// 直接用正文的字体度量，图底对齐基线时仍要保留基线以下的空间。
  TextStyle _paragraphFont(ContentBlock block, int offset) {
    final style = _styleOf(
      block,
      sourceOffset: offset,
      sourceEnd: offset + block.runLength,
    ).computed;
    return _sourceFont(block, style);
  }

  TextStyle _sourceFont(ContentBlock block, ComputedStyle style) {
    final run = ResolvedRunStyle.fromStyle(
      style,
      tableFontRoot: authorTableCell
          ? options.settings.fontSize.toDouble()
          : null,
    );
    final text = options.textStyleFor(
      block.kind,
      level: block.level,
      bold: run.bold,
      italic: run.italic,
      hasFontSize: run.hasFontSize,
      sizeScale: run.sizeScale,
      hasFontWeight: style.text.fontWeight != null,
    );
    return options.publicationFonts.apply(
      _specifiedLineHeight(
        text,
        style.text.lineHeight,
        useAuthorHeight: flatNest,
      ),
      options.settings.useBookFontsInSimplified
          ? style.text.fontFamilies
          : null,
    );
  }

  ({double height, double baseline}) _lineStrut(TextStyle? style) {
    final painter = TextPainter(
      text: TextSpan(
        text: '国',
        style: style ?? options.textStyleFor(BlockKind.paragraph),
      ),
      textDirection: TextDirection.ltr,
      textScaler: options.textScaler,
    )..layout();
    final metrics = painter.computeLineMetrics().first;
    painter.dispose();
    return (height: metrics.height, baseline: metrics.baseline);
  }
}

/// 当只含一张图的段落和另一张图叠放时，图底到文字行底的空间仍参与两图间距。
extension ImageLineSpacing on BlockMeasurer {
  double imageBaselineTail(int index) {
    final source = displayTree?.source;
    final image = source?.ownerOfBlock(index);
    if (image == null || image.tag != 'img') return 0;
    final style = styleTable?[image.styleId ?? 0] ?? ComputedStyle.empty;
    final align = style.text.verticalAlign;
    if (!isInlineDisplay(displayOf(image, style)) ||
        (align != null &&
            (align is! VerticalAlignKeyword || align.keyword != 'baseline'))) {
      return 0;
    }
    final parent = source?.element(image.parent ?? -1);
    if (parent == null ||
        parent.firstBlock != index ||
        parent.lastBlock != index) {
      return 0;
    }
    final parentStyle = styleTable?[parent.styleId ?? 0] ?? ComputedStyle.empty;
    final run = ResolvedRunStyle.fromStyle(parentStyle);
    final text = options.textStyleFor(
      BlockKind.paragraph,
      sizeScale: run.sizeScale,
      hasFontSize: run.hasFontSize,
      bold: run.bold,
      italic: run.italic,
    );
    final font = options.publicationFonts.apply(
      _specifiedLineHeight(
        text,
        parentStyle.text.lineHeight,
        useAuthorHeight: true,
      ),
      options.settings.useBookFontsInSimplified
          ? parentStyle.text.fontFamilies
          : null,
    );
    final strut = _lineStrut(
      font.copyWith(leadingDistribution: TextLeadingDistribution.even),
    );
    // Flutter 的行高取整但基线保留小数；CSS 行盒保留声明行高，
    // 字体基线落在像素上。小数 em 下不能把这两个舍入方向颠倒。
    final lineHeight = font.height == null
        ? strut.height
        : options.textScaler.scale(font.fontSize!) * font.height!;
    return math.max(0, lineHeight - strut.baseline.round());
  }
}

// 百分比相对元素自身的行高。只有作者用了百分比且未指定行高时才查询字体度量。
double _inlineBaselineLift(
  ComputedStyle style,
  LengthContext context,
  double Function() normalHeight,
) {
  final align = style.text.verticalAlign;
  if (align is! VerticalAlignLength) return 0;
  final length = align.length;
  if (length is! PercentLength) return length.resolve(context);
  final line =
      style.text.lineHeight?.resolvePx(
        fontSize: context.fontSize,
        rootFontSize: context.rootFontSize,
      ) ??
      normalHeight();
  return length.resolve(context.copyWith(reference: line));
}

(double, double) _alignInlineObjects(
  List<_InlineSpec> images, {
  required double above,
  required double below,
  required double contentHeight,
  required double imageHeight,
  required ({double height, double baseline}) strut,
}) {
  var alignBaseline = false, topHeight = 0.0, bottomHeight = 0.0;
  for (final image in images) {
    if (image.textBox case final atom? when image.verticalAlign == 'baseline') {
      alignBaseline = true;
      final baseline = atom.baseline + image.baselineLift;
      above = math.max(above, baseline);
      below = math.max(below, image.size.height - baseline);
    } else if (image.formula case final formula?) {
      alignBaseline = true;
      above = math.max(above, formula.baseline);
      below = math.max(below, image.size.height - formula.baseline);
    } else if (!image.blockDisplay) {
      switch (image.verticalAlign) {
        case 'baseline':
          alignBaseline = true;
          above = math.max(
            above,
            math.max(strut.baseline, image.size.height + image.baselineLift),
          );
          below = math.max(
            below,
            math.max(strut.height - strut.baseline, -image.baselineLift),
          );
        case 'top':
          topHeight = math.max(topHeight, image.size.height);
        case 'bottom':
          bottomHeight = math.max(bottomHeight, image.size.height);
      }
    }
  }
  final text = alignBaseline
      ? above + below
      : math.max(contentHeight, above + below);
  final height = math.max(text, imageHeight);
  final shift = bottomHeight > text
      ? bottomHeight - text
      : (alignBaseline || topHeight > 0 ? 0.0 : (height - text) / 2);
  return (height, above + shift);
}

/// 测量用的行内图片：块内位置与已换算好的显示尺寸。
class _InlineSpec {
  _InlineSpec({
    required this.offset,
    required this.size,
    required this.resourcePath,
    this.alt,
    this.left = 0,
    this.content,
    this.imageFit,
    this.box,
    this.margin = EdgeInsets.zero,
    this.elementId = -1,
    this.blockDisplay = false,
    this.breakAfter = false,
    this.formula,
    this.textBox,
    this.noteLink,
    this.altIsFootnote = false,
    this.verticalAlign,
    this.baselineLift = 0,
  });

  final int offset;
  final bool blockDisplay;
  final bool breakAfter;
  final Size size;
  final Size? content;
  final BookImageFit? imageFit;
  final BlockBox? box;
  final EdgeInsets margin;
  final int elementId;
  final String resourcePath;
  final String? alt;
  final FormulaGeometry? formula;
  final _InlineTextBox? textBox;
  final String? noteLink;
  final bool altIsFootnote;
  final String? verticalAlign;
  final double baselineLift;

  _InlineSpec at(double x) => _InlineSpec(
    offset: offset,
    size: size,
    resourcePath: resourcePath,
    alt: alt,
    left: x,
    content: content,
    imageFit: imageFit,
    box: box,
    margin: margin,
    elementId: elementId,
    formula: formula,
    textBox: textBox,
    blockDisplay: blockDisplay,
    breakAfter: breakAfter,
    noteLink: noteLink,
    altIsFootnote: altIsFootnote,
    verticalAlign: verticalAlign,
    baselineLift: baselineLift,
  );

  double topInLine(double height, double baseline) {
    if (formula != null) return baseline - formula!.baseline;
    if (blockDisplay) return 0;
    return switch (verticalAlign) {
      'baseline' =>
        baseline - (textBox?.baseline ?? size.height) - baselineLift,
      'top' => 0,
      'bottom' => height - size.height,
      _ => (height - size.height) / 2,
    };
  }

  /// 在这一行里的横向起点（测量过程中填入）。
  final double left;
}
