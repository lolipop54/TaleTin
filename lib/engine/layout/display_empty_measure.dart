part of 'block_measure.dart';

extension DisplayEmptyMeasurement on BlockMeasurer {
  /// 空元素只产生显示装饰，锚点借用相邻正文；它不占正文块号和文字长度。
  List<MeasuredBlock> measureBefore(int blockIndex) {
    final tree = displayTree;
    if (tree == null) return const [];
    final result = <MeasuredBlock>[];
    for (final node in tree.emptyBefore(blockIndex)) {
      final measured = _measureEmptyNode(node, blockIndex);
      // 无尺寸、无边距的空标签没有布局效果，不能额外制造段距。
      if (measured.height > 0 ||
          measured.marginTop != 0 ||
          measured.marginBottom != 0) {
        result.add(measured);
      }
    }
    return result;
  }

  MeasuredBlock _measureEmptyNode(DisplayNode node, int blockIndex) {
    final chain = displayTree!.chainOfEmpty(node);
    final outer = DisplayBoxLayout.resolve(
      chain.take(chain.length - 1).toList(),
      styleTable,
      options,
    );
    final child = _measureEmpty(
      node,
      blockIndex,
      outer.width,
      outer.left,
      indentDepth: chain
          .take(chain.length - 1)
          .where((c) => c.isQuoteOrList)
          .length,
    );
    return MeasuredBlock(
      blockId: child.blockId,
      kind: child.kind,
      isDecoration: true,
      decorationAtStart: blockIndex == 0,
      height: child.height + outer.top + outer.bottom,
      layoutWidth: child.layoutWidth,
      marginTop: child.marginTop,
      marginBottom: child.marginBottom,
      containerBoxes: [
        ...outer.frames,
        for (final f in child.containerBoxes)
          ContainerBoxFrame(
            elementId: f.elementId,
            box: f.box,
            first: f.first,
            last: f.last,
            left: f.left,
            width: f.width,
            top: f.top + outer.top,
            height: f.height,
            bottom: f.bottom,
          ),
      ],
    );
  }

  MeasuredBlock _measureEmpty(
    DisplayNode node,
    int anchor,
    double available,
    double left, {
    int indentDepth = 0,
  }) {
    final style = styleTable?[node.element.styleId ?? 0] ?? ComputedStyle.empty;
    final geometry = DisplayBoxLayout.resolve(
      [
        DisplayContainer(
          elementId: node.element.id,
          styleId: node.element.styleId ?? 0,
          first: true,
          last: true,
          role: node.element.role,
          tag: node.element.tag,
        ),
      ],
      styleTable,
      options,
      available: available,
      origin: left,
      initialIndentDepth: indentDepth,
    );
    final context = _lengthContext(style, available);
    double px(Length? value) =>
        value == null || value.isAuto ? 0 : value.resolve(context);
    final box = geometry.chain.firstOrNull?.$2;
    // 空容器也使用统一计算得到的内容宽度与左边缘，不能重新按整页算。
    final innerWidth = geometry.width;
    final width = innerWidth + (box?.insetLeft ?? 0) + (box?.insetRight ?? 0);
    final frames = <ContainerBoxFrame>[];
    var used = box?.insetTop ?? 0.0;
    for (final child in node.children.where(
      (n) => n.isBlock && n.element.firstBlock == null,
    )) {
      final measured = _measureEmpty(
        child,
        anchor,
        innerWidth,
        geometry.left,
        indentDepth:
            indentDepth +
            (const {'blockquote', 'ul', 'ol', 'dl'}.contains(node.element.tag)
                ? 1
                : 0),
      );
      for (final frame in measured.containerBoxes) {
        frames.add(
          ContainerBoxFrame(
            elementId: frame.elementId,
            box: frame.box,
            first: true,
            last: true,
            left: frame.left,
            width: frame.width,
            top: used + frame.top,
            height: frame.height,
          ),
        );
      }
      used += measured.height;
    }
    final natural = used + (box?.insetBottom ?? 0);
    final explicit =
        px(style.size.height) + (box?.insetTop ?? 0) + (box?.insetBottom ?? 0);
    final height = math.max(
      natural,
      math.max(explicit, px(style.size.minHeight)),
    );
    if (box != null) {
      frames.insert(
        0,
        ContainerBoxFrame(
          elementId: node.element.id,
          box: box,
          first: true,
          last: true,
          left: geometry.left - box.insetLeft,
          width: width,
          height: height,
        ),
      );
    }
    final ordered = treeIds;
    final target = ordered.isEmpty
        ? ''
        : ordered[anchor.clamp(0, ordered.length - 1)];
    return MeasuredBlock(
      blockId: target,
      kind: BlockKind.paragraph,
      isDecoration: true,
      decorationAtStart: anchor == 0,
      height: height,
      layoutWidth: width,
      containerBoxes: frames,
      marginTop: px(style.block.margin?.top),
      marginBottom: px(style.block.margin?.bottom),
    );
  }

  List<String> get treeIds =>
      displayTree!.blockIndexById.keys.toList(growable: false);
}
