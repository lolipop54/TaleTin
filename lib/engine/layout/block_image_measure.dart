part of 'block_measure.dart';

extension BlockImageMeasurement on BlockMeasurer {
  /// 图片如果落在书内的引用框／背景框里，左右内边距要缩小可用宽度，
  /// 上下内边距计入块高度，盒子才会连续地包住图片。
  MeasuredBlock _measureImage(ContentBlock block) {
    if (normalFlow && block.id == displayTree?.coverBlockId) {
      final width = options.contentWidth + 2 * options.paperInset.dx;
      final top = options.paperInset.dy;
      final height =
          options.contentHeight + top + (options.paperBottomInset ?? top);
      final natural = Size(
        block.resourceWidth!.toDouble(),
        block.resourceHeight!.toDouble(),
      );
      final size =
          natural * math.min(width / natural.width, height / natural.height);
      final offset = (height - size.height) / 2 - top;
      // 正文流只占满一页，图片与点按区域可以延伸到上、下信息栏。
      return MeasuredBlock(
        blockId: block.id,
        kind: block.kind,
        paperArtwork: true,
        resourcePath: block.resourcePath,
        alt: block.alt,
        noteLink: block.noteLink,
        altIsFootnote: block.altIsFootnote,
        imageSize: size,
        inset: -options.paperInset.dx,
        align: 'center',
        layoutWidth: width,
        height: options.contentHeight,
        bodyTop: offset,
        bodyBottom: options.contentHeight - size.height - offset,
      );
    }
    final style = _styleOf(block);
    final spacing = _insetOf(block, style);
    final box = spacing.box;
    final index = displayTree?.blockIndexById[block.id];
    final positioned = DisplayPosition.isPageImage(
      style.computed,
      displayTree,
      index,
    );
    final context = _lengthContext(style.computed, spacing.containerWidth);
    double? pixels(Length? value) =>
        value == null || value.isAuto ? null : value.resolve(context);
    final margin = style.computed.block.margin;
    final left = pixels(margin?.left) ?? 0.0;
    final right = pixels(margin?.right) ?? 0.0;
    final opening = displayTree?.openingArtwork;
    final edges = !positioned && normalFlow && opening?.id == block.id
        ? opening!.edges
        : 0;
    final leftBleed = edges & 1 != 0
        ? options.paperInset.dx + spacing.left + left
        : 0.0;
    final rightBleed = edges & 4 != 0
        ? options.paperInset.dx + spacing.rightSpace + right
        : 0.0;
    final topBleed = edges & 2 != 0 ? options.paperInset.dy : 0.0;
    final maxWidth = math.max(
      1.0,
      options.contentWidth +
          leftBleed +
          rightBleed -
          spacing.left -
          spacing.rightSpace -
          (positioned ? 0.0 : left + right),
    );
    final maxHeight =
        options.contentHeight +
        topBleed -
        (box?.insetTop ?? 0) -
        spacing.outerTop;
    final containerBoxes = _containerFramesOf(spacing, maxWidth);
    final bodyTop = (box?.insetTop ?? 0) + spacing.outerTop - topBleed;
    final bodyBottom = (box?.insetBottom ?? 0) + spacing.outerBottom;
    // 原图等比量到纸边；顶部进入信息区的部分不重复占用正文高度。
    final size = edges != 0 && options.paperInset != Offset.zero
        ? Size(
                block.resourceWidth!.toDouble(),
                block.resourceHeight!.toDouble(),
              ) *
              math.min(
                maxWidth / block.resourceWidth!,
                maxHeight / block.resourceHeight!,
              )
        : imageSizeIn(
            block,
            style.computed,
            context,
            box,
            maxWidth,
            maxHeight,
            spacing.containerHeight,
          );
    final align = positioned
        ? 'left'
        : margin?.left?.isAuto == true
        ? (margin?.right?.isAuto == true ? 'center' : 'right')
        : margin?.right?.isAuto == true
        ? 'left'
        : style.align;
    final imageLeft = positioned
        ? DisplayPosition.offset(
            style.computed,
            options,
            maxWidth,
            options.contentHeight,
            size.width,
            vertical: false,
          )!
        : left;
    final image = MeasuredBlock(
      blockId: block.id,
      kind: BlockKind.image,
      imageSize: size,
      paperArtwork: edges != 0 && options.paperInset != Offset.zero,
      imageFit: BookImageFit.of(
        style.computed.size.objectFit,
        block.resourceWidth,
        block.resourceHeight,
      ),
      resourcePath: block.resourcePath,
      alt: block.alt,
      noteLink: block.noteLink,
      altIsFootnote: block.altIsFootnote,
      inset: spacing.left + imageLeft - leftBleed,
      layoutWidth: maxWidth,
      align: align,
      height: size.height + bodyTop + bodyBottom,
      box: box,
      boxId: block.boxId,
      containerBoxes: containerBoxes,
      bodyTop: bodyTop,
      bodyBottom: bodyBottom,
      marginTop: positioned ? 0.0 : (pixels(margin?.top) ?? 0.0),
      marginBottom: positioned ? 0.0 : (pixels(margin?.bottom) ?? 0.0),
      flowMargins: positioned ? null : spacing.margins,
      isDecoration: positioned,
    );
    final entry = displayTree?.portraits[block.id];
    if (entry != null && !positioned && normalFlow && paginated) {
      final name = measure(
        entry.name,
        withIndent:
            options.settings.indent && entry.name.kind == BlockKind.paragraph,
      );
      final bio = measure(entry.bio, withIndent: options.settings.indent);
      final available =
          options.contentHeight -
          name.height -
          gapBefore(name, image) -
          gapBefore(image, bio) -
          biographyStartHeight(bio) -
          bodyTop -
          bodyBottom;
      if (available > 0 && available < size.height) {
        return image.withBoxEdges(
          first: image.boxFirst,
          last: image.boxLast,
          height: available + bodyTop + bodyBottom,
          imageSize: size * (available / size.height),
        );
      }
      return image;
    }
    final caption = displayTree?.galleryCaptions[block.id];
    if (caption == null || positioned || !normalFlow) return image;
    final label = measure(
      caption,
      withIndent:
          options.settings.indent && caption.kind == BlockKind.paragraph,
    );
    if (label.pageTop != null || !label.isText) return image;
    return fitGalleryImage(
      image,
      label,
      options.contentHeight,
      gapBefore(image, label),
    );
  }

  /// 普通图片和定位图片用相同的固有比例、作者尺寸与单页缩放规则。
  Size imageSizeIn(
    ContentBlock block,
    ComputedStyle style,
    LengthContext context,
    BlockBox? box,
    double maxWidth,
    double maxHeight,
    double? parentHeight,
  ) {
    final rawWidth = (block.resourceWidth ?? 0).toDouble();
    final rawHeight = (block.resourceHeight ?? 0).toDouble();
    // 尺寸嗅探失败时沿用 1:1 兜底。先按包含块选定尺寸，再做阅读页缩放。
    final ratioOnly = block.svgRatioOnly && rawWidth > 0 && rawHeight > 0;
    final intrinsicWidth = ratioOnly || rawWidth <= 0 ? maxWidth : rawWidth;
    final intrinsicHeight = ratioOnly
        ? intrinsicWidth / rawWidth * rawHeight
        : (rawHeight > 0 ? rawHeight : intrinsicWidth);
    final sizeOfBox = BoxSizeResolver(
      context,
      style.size,
      box,
      parentHeight: parentHeight,
    ).image(Size(intrinsicWidth, intrinsicHeight));
    var scale = 1.0;
    if (sizeOfBox.width > maxWidth) scale = maxWidth / sizeOfBox.width;
    if (sizeOfBox.height * scale > maxHeight && sizeOfBox.height > 0) {
      scale = math.max(0, maxHeight / sizeOfBox.height);
    }
    return sizeOfBox * scale;
  }

  List<MeasuredBlock> pageImagesOf(ChapterContent content) {
    final source = displayTree?.source;
    if (source == null) return const [];
    return [
      for (final element in source.elements)
        if (element.tag == 'img')
          if (element.firstBlock case final index?)
            if (!displayTree!.hiddenBlocks.contains(index) &&
                content.blocks[index].kind == BlockKind.image &&
                source.ownerOfBlock(index)?.id == element.id &&
                DisplayPosition.isPageImage(
                  styleTable?[element.styleId ?? 0] ?? ComputedStyle.empty,
                  displayTree,
                  index,
                ))
              measure(content.blocks[index], withIndent: false),
    ];
  }

  /// 把图片的 `[数值, 单位]` 换算成像素。数值是单位的 1/100；
  /// 单位 1 百分比（按正文宽度）、2 em（按正文字号）、3 px。
  double? _imageLength(List<int>? spec, double contentWidth) {
    if (spec == null || spec.length < 2) return null;
    final value = spec[0].toDouble();
    final pixels = switch (spec[1]) {
      1 => contentWidth * value / 10000,
      2 => options.settings.fontSize * value / 100,
      3 => value / 100,
      _ => 0.0,
    };
    return pixels > 0 ? pixels : null;
  }
}
