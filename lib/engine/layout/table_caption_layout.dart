part of 'table_layout.dart';

/// 表题的包含块是已经算出的整表宽度。它的边距留在表格边框之外。
class _TableCaption {
  _TableCaption(
    this.side,
    this.left,
    this.width,
    this.height,
    this.marginTop,
    this.marginBottom,
    this.box,
    this.items,
  );
  final String side;
  bool get bottom => side == 'bottom';
  final double left, width, height, marginTop, marginBottom;
  final BlockBox? box;
  final List<_CellItem> items;
  double get extent => marginTop + height + marginBottom;
}

double _captionMinimum(
  List<DisplayNode> nodes,
  DisplayTree tree,
  StyleTable styles,
  LayoutOptions options,
  Map<String, ContentBlock> blocks,
  double available,
  BlockMeasurer probe,
) {
  var minimum = 0.0;
  for (final node in nodes) {
    final style = styles[node.element.styleId ?? 0];
    final context = DisplayBoxLayout.context(
      style,
      options,
      available,
      authorTableCell: true,
    );
    final box = resolveBlockBox(style.box, context);
    final intrinsic = _contentIntrinsic(
      tree.blocksOf(node),
      blocks,
      tree,
      styles,
      probe,
      style.text.whiteSpace,
    ).$1;
    final size = BoxSizeResolver.widthOf(context, style.size, box);
    final fixed = style.size.width is PercentLength
        ? size.constrain(intrinsic)
        : size.use(intrinsic);
    double absolute(Length? length) =>
        length == null || length.isAuto || length is PercentLength
        ? 0
        : length.resolve(context);
    minimum = math.max(
      minimum,
      fixed +
          (box?.insetLeft ?? 0) +
          (box?.insetRight ?? 0) +
          absolute(style.block.margin?.left) +
          absolute(style.block.margin?.right),
    );
  }
  return minimum;
}

List<_TableCaption> _measureCaptions(
  List<DisplayNode> nodes,
  DisplayTree tree,
  StyleTable styles,
  LayoutOptions options,
  Map<String, ContentBlock> blocks,
  double tableWidth,
  BlockMeasurer Function(double, double) measurer,
) {
  final captions = <_TableCaption>[];
  for (final node in nodes) {
    final style = styles[node.element.styleId ?? 0];
    final ctx = DisplayBoxLayout.context(
      style,
      options,
      tableWidth,
      authorTableCell: true,
    );
    final box = resolveBlockBox(style.box, ctx);
    final size = BoxSizeResolver(ctx, style.size, box);
    final margin = style.block.margin;
    double px(Length? v) => v == null || v.isAuto ? 0 : v.resolve(ctx);
    final edges = (box?.insetLeft ?? 0) + (box?.insetRight ?? 0);
    final width = math.max(
      1.0,
      size.width.use(tableWidth - edges - px(margin?.left) - px(margin?.right)),
    );
    final spare = math.max(0.0, tableWidth - width - edges - px(margin?.right));
    final left = margin?.left?.isAuto == true
        ? spare / (margin?.right?.isAuto == true ? 2 : 1)
        : px(margin?.left);
    final probe = measurer(width, options.contentHeight);
    final items = <_CellItem>[];
    var y = 0.0;
    for (final id in tree.blocksOf(node)) {
      final index = tree.blockIndexById[id]!;
      if (tree.hiddenBlocks.contains(index)) continue;
      final block = probe.measure(blocks[id]!);
      final own = tree.source!.ownerOfBlock(index)?.id == node.element.id;
      if (!own) y += block.marginTop;
      items.add((
        block: block,
        width: width,
        top: y + (box?.insetTop ?? 0),
        left: box?.insetLeft ?? 0,
      ));
      y += block.lines.isEmpty
          ? block.height
          : _sum(block.lines.map((l) => l.height));
      if (!own) y += block.marginBottom;
    }
    if (items.isEmpty) {
      items.add((
        block: MeasuredBlock(
          blockId: '__caption_${node.element.id}',
          kind: BlockKind.paragraph,
          isDecoration: true,
        ),
        width: width,
        top: 0,
        left: 0,
      ));
    }
    captions.add(
      _TableCaption(
        style.table.captionSide ?? 'top',
        left,
        width + edges,
        size.height.use(y) + (box?.insetTop ?? 0) + (box?.insetBottom ?? 0),
        px(margin?.top),
        px(margin?.bottom),
        box,
        items,
      ),
    );
  }
  return captions;
}
