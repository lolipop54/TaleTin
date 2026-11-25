part of 'block_measure.dart';

extension DisplayEmptyMeasurement on BlockMeasurer {
  bool isClosingFloatOrnament(MeasuredBlock block) {
    final tree = displayTree;
    if (tree == null ||
        block.text.trim().runes.length != 1 ||
        !RegExp(r'^[\p{S}\p{P}]$', unicode: true).hasMatch(block.text.trim())) {
      return false;
    }
    final i = tree.blockIndexById[block.blockId];
    return i == tree.chains.length - 1 && _emptyFloatsBeside(i!) != null;
  }

  /// 空元素只产生显示装饰，锚点借用相邻正文；它不占正文块号和文字长度。
  List<MeasuredBlock> measureBefore(int blockIndex) {
    final tree = displayTree;
    if (tree == null) return const [];
    final result = <MeasuredBlock>[];
    final attached = _emptyFloatsBeside(blockIndex)?.nodes;
    for (final node in tree.emptyBefore(blockIndex)) {
      if (attached?.contains(node) == true) continue;
      final grid = tree.emptyGrids[node.element.id];
      if (grid != null && styleTable != null && tree.authoritative) {
        result.addAll(measureEmptyGrid(grid, node, tree, styleTable!, options));
        continue;
      }
      final measured = _measureEmptyNode(node, blockIndex);
      // 无尺寸、无边距的空标签没有布局效果，不能额外制造段距。
      if (measured.height > 0 ||
          measured.leadingMargin.positive != 0 ||
          measured.leadingMargin.negative != 0 ||
          measured.trailingMargin.positive != 0 ||
          measured.trailingMargin.negative != 0) {
        result.add(measured);
      }
    }
    return result;
  }

  /// 同一个容器里，直接文字两侧的扁平装饰可和文字共用一行。
  /// 用作者的宽高计算装饰和中间的可用文字宽度，避免为空盒子单独增加一行。
  ({
    List<DisplayNode> nodes,
    List<ContainerBoxFrame> frames,
    double left,
    double right,
  })?
  _emptyFloatsBeside(int index) {
    final tree = displayTree!;
    final siblings = tree.emptyBefore(index);
    if (siblings.length < 2) return null;
    final owner = tree.source?.ownerOfBlock(index);
    if (owner == null ||
        owner.firstBlock != index ||
        owner.lastBlock != index) {
      return null;
    }
    final nodes = siblings.where((node) {
      final style = styleTable?[node.element.styleId ?? 0];
      return node.element.parent == owner.id &&
          style?.size.width?.isAuto == false &&
          const {FloatSpec.left, FloatSpec.right}.contains(style?.block.float);
    }).toList();
    if (nodes.length != 2) return null;
    final geometry = DisplayBoxLayout.resolve(
      tree.chainOf(index, merged: nodes),
      styleTable,
      options,
      tree: displayTree,
      blockOwnerId: owner.id,
      collapseMargins: _canCollapseMargins(owner),
    );
    final font = options.textScaler.scale(options.settings.fontSize.toDouble());
    final frames = <ContainerBoxFrame>[];
    var left = 0.0, right = 0.0;
    for (final node in nodes) {
      final empty = _measureEmpty(
        node,
        index,
        geometry.width,
        geometry.left,
        parentHeight: geometry.containerHeight,
      );
      final frame = empty.containerBoxes.firstOrNull;
      if (frame == null ||
          (frame.height ?? 0) <= 0 ||
          empty.height + empty.marginTop > font) {
        return null;
      }
      final style = styleTable![node.element.styleId ?? 0];
      final isRight = style.block.float == FloatSpec.right;
      if (isRight) {
        if (right > 0) return null;
        right = frame.width;
      } else {
        if (left > 0) return null;
        left = frame.width;
      }
      frames.add(
        ContainerBoxFrame(
          elementId: frame.elementId,
          box: frame.box,
          first: true,
          last: true,
          left: isRight
              ? geometry.left + geometry.width - right
              : geometry.left,
          width: frame.width,
          top: geometry.top + empty.marginTop,
          height: frame.height,
          lineTo: 1,
        ),
      );
    }
    if (geometry.width - left - right < font || tree.textLengths[index] == 0) {
      return null;
    }
    return (nodes: nodes, frames: frames, left: left, right: right);
  }

  MeasuredBlock _measureEmptyNode(DisplayNode node, int blockIndex) {
    final chain = displayTree!.chainOfEmpty(node);
    final style = styleTable?[node.element.styleId ?? 0] ?? ComputedStyle.empty;
    final collapse = _canCollapseMargins(node.element);
    final outer = DisplayBoxLayout.resolve(
      chain.take(chain.length - 1).toList(),
      styleTable,
      options,
      tree: displayTree,
      ownStyle: collapse ? style : null,
      constrainOwnWidth: false,
      collapseMargins: collapse,
    );
    final child = _measureEmpty(
      node,
      blockIndex,
      outer.width,
      outer.left,
      parentHeight: outer.containerHeight,
      collapseMargins: collapse,
      expandQuotes: outer.expandQuotes,
      indentDepth: chain
          .take(chain.length - 1)
          .where((c) => c.isQuoteOrList)
          .length,
    );
    final height = child.height + outer.top + outer.bottom;
    final margin = outer.margins;
    final through = height == 0 && child.collapsesThrough;
    return MeasuredBlock(
      blockId: child.blockId,
      kind: child.kind,
      isDecoration: true,
      decorationAtStart: blockIndex == 0,
      height: height,
      layoutWidth: child.layoutWidth,
      marginTop: child.marginTop,
      marginBottom: child.marginBottom,
      flowMargins: margin == null || !through
          ? margin
          : BlockMargins(
              margin.before.join(child.leadingMargin),
              margin.after.join(child.trailingMargin),
              through: true,
            ),
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
    bool expandQuotes = false,
    double? parentHeight,
    bool collapseMargins = false,
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
      tree: displayTree,
      available: available,
      availableHeight: parentHeight,
      origin: left,
      initialIndentDepth: indentDepth,
      expandQuotes: expandQuotes,
    );
    final context = _lengthContext(style, available);
    double px(Length? value) =>
        value == null || value.isAuto ? 0 : value.resolve(context);
    final box = geometry.chain.firstOrNull?.$2;
    final size = BoxSizeResolver.heightOf(
      context,
      style.size,
      box,
      parentHeight: parentHeight,
    );
    // 空容器也使用统一计算得到的内容宽度与左边缘，不能重新按整页算。
    final innerWidth = geometry.width;
    final width = innerWidth + (box?.insetLeft ?? 0) + (box?.insetRight ?? 0);
    final frames = <ContainerBoxFrame>[];
    var collapsed = const VerticalMargin.zero();
    var through =
        collapseMargins && !DisplayBoxLayout.establishesBlockContext(style);
    var used = box?.insetTop ?? 0.0;
    for (final child in node.children.where(
      (n) => n.isBlock && n.element.firstBlock == null,
    )) {
      final measured = _measureEmpty(
        child,
        anchor,
        innerWidth,
        geometry.left,
        parentHeight: geometry.containerHeight,
        collapseMargins: collapseMargins && _canCollapseMargins(child.element),
        expandQuotes: geometry.expandQuotes,
        indentDepth:
            indentDepth +
            (const {'blockquote', 'ul', 'ol', 'dl'}.contains(node.element.tag)
                ? 1
                : 0),
      );
      through = through && measured.collapsesThrough;
      if (through) {
        collapsed = collapsed
            .join(measured.leadingMargin)
            .join(measured.trailingMargin);
      }
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
    final insetTop = box?.insetTop ?? 0;
    final insetBottom = box?.insetBottom ?? 0;
    final natural = used - insetTop;
    // 子盒仍参与正常块流，不能被空装饰的指定高度盖住。
    final height =
        insetTop + math.max(natural, size.use(natural)) + insetBottom;
    final before = px(style.block.margin?.top);
    final after = px(style.block.margin?.bottom);
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
      marginTop: before,
      marginBottom: after,
      flowMargins: through && height == 0
          ? BlockMargins(
              VerticalMargin.of(before).join(collapsed),
              VerticalMargin.of(after).join(collapsed),
              through: true,
            )
          : null,
    );
  }

  List<String> get treeIds =>
      displayTree!.blockIndexById.keys.toList(growable: false);
}
