part of 'block_measure.dart';

extension _ImageWrapperMeasurement on BlockMeasurer {
  /// 段中只含图片的块按自己的宽度、对齐和边距排版。结果占整行；
  /// 负下边距减少留给下一行的高度，但不把下一行的脚注抬到题花顶端。
  _InlineSpec _measureImageWrapper(
    DisplayNode node,
    ContentBlock owner,
    int offset,
    double available,
    double? parentHeight,
    List<_InlineSpec> Function(double, double?) imagesAt,
  ) {
    final e = node.element;
    final style = styleTable?[e.styleId ?? 0] ?? ComputedStyle.empty;
    final geometry = DisplayBoxLayout.resolve(
      [
        DisplayContainer(
          elementId: e.id,
          styleId: e.styleId ?? 0,
          first: true,
          last: true,
          role: e.role,
          tag: e.tag,
        ),
      ],
      styleTable,
      options,
      available: available,
      availableHeight: parentHeight,
      blockOwnerId: e.id,
    );
    final margin = style.block.margin?.resolve(
      _lengthContext(style, available),
    );
    // 用已有的行内排版处理基线、多图换行、图片边框。图片不增加原文字符。
    final inner = _measureInlineText(
      block: ContentBlock(id: '', kind: owner.kind),
      runs: [TextRun('')],
      styles: [_sourceFont(owner, style)],
      text: '',
      width: geometry.width,
      contentWidth: geometry.width,
      inset: 0,
      markerInset: 0,
      box: null,
      textShadow: null,
      prefixLength: 0,
      marker: null,
      align: style.block.textAlign?.name ?? 'left',
      boxIndent: 0,
      marginTop: 0,
      marginBottom: 0,
      preparedImages: imagesAt(geometry.width, geometry.containerHeight),
    );
    final top = margin?.top ?? 0.0;
    final contentHeight =
        geometry.ownerHeight?.use(inner.height) ?? inner.height;
    final boxes = <InlineBoxPlacement>[];
    final images = <InlineImagePlacement>[];
    final frame = geometry.frames.firstOrNull;
    if (frame != null) {
      boxes.add(
        InlineBoxPlacement(
          span: InlineBoxSpan(
            start: offset,
            end: offset,
            id: e.id,
            box: const [],
          ),
          box: frame.box,
          line: 0,
          first: true,
          last: true,
          rect: Rect.fromLTWH(
            frame.left,
            top,
            frame.width,
            geometry.top + contentHeight + geometry.bottom,
          ),
        ),
      );
    }
    var y = top + geometry.top;
    for (final (i, line) in inner.lines.indexed) {
      final origin = Offset(
        geometry.left + inner.horizontalOffset(i, geometry.width),
        y,
      );
      for (final im in inner.inlineImagesInLines(i, i + 1)) {
        images.add(_shiftInlineImage(im, origin, 0, offset));
      }
      for (final box in inner.inlineBoxes.where((b) => b.line == i)) {
        boxes.add(_shiftInlineBox(box, origin, 0, offset));
      }
      y += line.height;
    }
    return _InlineSpec(
      offset: offset,
      elementId: e.id,
      resourcePath: '',
      blockDisplay: true,
      size: Size(
        available,
        math.max(
          0,
          top +
              geometry.top +
              contentHeight +
              geometry.bottom +
              (margin?.bottom ?? 0),
        ),
      ),
      textBox: _InlineTextBox(
        offset,
        0,
        const [],
        boxes: boxes,
        images: images,
      ),
    );
  }
}
