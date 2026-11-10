part of 'block_measure.dart';

/// 一块内容的横向缩进从哪里来。
///
/// 以前「自己的盒子」「引用容器」「列表内边距」「阅读器兜底缩进」分散在文字测量
/// 和图片测量里各写一遍，条件稍有不同就会一边缩进一边不缩进。这里按固定优先级
/// 算一次，文字、图片、表格单元格都读同一份结果：
///
/// 1. 元素自己的盒子（背景／边框／内边距）：盒子的内边距就是缩进，不再叠加兜底；
/// 2. 列表祖先自己已经扣掉的左内边距：列表用书里给的缩进，不再叠加固定 1.6em；
/// 3. 都没有时使用阅读器兜底：列表和引用只取一档、普通段落按块类型。
class _BlockInset {
  const _BlockInset({
    required this.box,
    required this.chain,
    required this.baseInset,
    required this.right,
    required this.outerLeft,
    required this.outerRight,
    required this.outerTop,
    required this.outerBottom,
    required this.containerWidth,
    this.frames = const [],
  });

  /// 块自己的盒子；没有写背景／边框／内边距时为 null。
  final BlockBox? box;

  /// 祖先容器链（外层→内层），只含真正有外观或内边距的层。
  final List<(DisplayContainer, BlockBox)> chain;

  /// 阅读器兜底缩进（不含自己的盒子和祖先容器）。
  final double baseInset;

  /// 阅读器兜底右侧留白（不含自己的盒子和祖先容器）。
  final double right;

  final double outerLeft, outerRight, outerTop, outerBottom;

  /// 扣掉祖先容器后、还没扣自己盒子内边距的可用宽度。
  /// 百分比外边距、百分比宽度用它作包含块宽度。
  final double containerWidth;
  final List<ContainerBoxFrame> frames;

  bool get boxed => box != null || chain.isNotEmpty;

  /// 文字／图片内容的左边缘（内容坐标）。
  double get left => baseInset + (box?.insetLeft ?? 0) + outerLeft;

  /// 右侧需要扣掉的总宽度。
  double get rightSpace => right + (box?.insetRight ?? 0) + outerRight;
}

extension _BlockInsetMeasurement on BlockMeasurer {
  /// 算出这一块的缩进来源。规则顺序写在 [_BlockInset] 上。
  ///
  /// [sourceOffset]／[sourceEnd] 给长段滚动切片用：判断容器首尾时以切片实际
  /// 覆盖的正文范围为准，不能把整章的首尾当成切片的首尾。
  _BlockInset _insetOf(
    ContentBlock block,
    ResolvedBlockStyle style, {
    int sourceOffset = 0,
    int? sourceEnd,
  }) {
    if (flatNest) {
      // 表格单元格：位置已经由列宽决定，不能再叠加引用／列表的嵌套缩进。
      return _BlockInset(
        box: null,
        chain: const [],
        baseInset: 0,
        right: 0,
        outerLeft: 0,
        outerRight: 0,
        outerTop: 0,
        outerBottom: 0,
        containerWidth: options.contentWidth,
      );
    }
    final index = displayTree?.blockIndexById[block.id];
    final ownStyle = index != null && displayTree!.ownsContainer(index)
        ? null
        : style.computed;
    final containers = index == null
        ? const <DisplayContainer>[]
        : displayTree!.chainOf(
            index,
            sourceOffset: sourceOffset,
            sourceEnd: sourceEnd,
          );
    final geometry = DisplayBoxLayout.resolve(
      containers,
      styleTable,
      options,
      ownStyle: ownStyle,
      // 图片尺寸随后由 _measureImage 按自己的 width 处理，不能扣两遍。
      constrainOwnWidth: block.kind != BlockKind.image,
      ownHeading: block.kind == BlockKind.heading,
    );
    final chain = geometry.chain;
    final containerWidth = geometry.containerWidth;
    final box = geometry.ownBox;
    final boxed = box != null || chain.isNotEmpty;
    final group = containers.where((c) => c.isQuoteOrList).firstOrNull;
    final groupStyle = group == null ? null : styleTable?[group.styleId];
    final groupContext = groupStyle == null
        ? null
        : _lengthContext(groupStyle, containerWidth);
    final hasGroupMargin =
        groupStyle != null &&
        [
          groupStyle.block.margin?.left,
          groupStyle.block.margin?.right,
        ].any((m) => m != null && !m.isAuto && m.resolve(groupContext!) > 0);
    // 列表祖先已经扣了多少左内边距；扣过就不再叠加阅读器的固定缩进。
    // 只看「有没有列表盒子」不够：只设背景、没设 padding 的列表也让盒子
    // 非空，但文字仍然需要一档缩进才能放下列表标记。
    final listInset = chain
        .where((entry) => entry.$1.role == 'list')
        .fold(0.0, (sum, entry) => sum + entry.$2.insetLeft);
    var baseInset = block.kind == BlockKind.listItem
        ? (listInset > 0 || geometry.left > 0
              ? 0.0
              : options.listIndentFor(
                  nest: boxed && style.nest > 0 ? style.nest - 1 : style.nest,
                ))
        // 作者首层外边距已经提供了引用缩进，不能再加阅读器的兜底两字。
        : (boxed || hasGroupMargin
              ? 0.0
              : options.insetFor(block.kind, nest: style.nest));
    // 圆点在正文左侧；有外框时至少在框内留出标记自身的空间。
    if (block.kind == BlockKind.listItem &&
        style.listStyle != 0 &&
        chain.isNotEmpty) {
      final innerLeft = chain.last.$1.elementId;
      final frame = geometry.frames.firstWhere((f) => f.elementId == innerLeft);
      final edge = frame.left + frame.box.borderLeft;
      baseInset = math.max(
        baseInset,
        edge +
            options.settings.fontSize * .8 -
            geometry.left -
            (box?.insetLeft ?? 0),
      );
    }
    final right = boxed || hasGroupMargin
        ? 0.0
        : options.rightInsetFor(block.kind, nest: style.nest);
    return _BlockInset(
      box: box,
      chain: chain,
      baseInset: baseInset,
      right: right,
      outerLeft: geometry.left,
      outerRight: geometry.right,
      outerTop: geometry.top,
      outerBottom: geometry.bottom,
      containerWidth: containerWidth,
      frames: geometry.frames,
    );
  }
}
