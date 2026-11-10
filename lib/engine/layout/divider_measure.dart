part of 'block_measure.dart';

extension _DividerMeasurement on BlockMeasurer {
  MeasuredBlock _measureDivider(ContentBlock block) {
    final style = _styleOf(block), spacing = _insetOf(block, style);
    final index = displayTree?.blockIndexById[block.id];
    final css =
        index != null && displayTree?.source?.ownerOfBlock(index)?.tag == 'hr';
    // 原生 hr 即使 border:none 也不能退回短线；空盒子明确表示不画边框。
    final box = css
        ? spacing.box ??
              const BlockBox(
                background: null,
                borderColors: [
                  Color(0x00000000),
                  Color(0x00000000),
                  Color(0x00000000),
                  Color(0x00000000),
                ],
                borderTop: 0,
                borderRight: 0,
                borderBottom: 0,
                borderLeft: 0,
                shadows: [],
                padTop: 0,
                padRight: 0,
                padBottom: 0,
                padLeft: 0,
              )
        : spacing.box;
    final top = (box?.insetTop ?? 0) + spacing.outerTop;
    final bottom = (box?.insetBottom ?? 0) + spacing.outerBottom;
    final width = options.contentWidth - spacing.left - spacing.rightSpace;
    final lengths = _lengthContext(style.computed, spacing.containerWidth);
    var height = kDividerHeight;
    if (css) {
      final context = lengths.copyWith(reference: options.contentHeight);
      double? px(Length? value) =>
          value == null || value.isAuto ? null : value.resolve(context);
      final size = style.computed.size;
      final borderBox = size.boxSizing == BoxSizingSpec.borderBox;
      final edges = box!.insetTop + box.insetBottom;
      double content(double value) =>
          math.max(0, value - (borderBox ? edges : 0));
      height = content(px(size.height) ?? 0);
      if (px(size.maxHeight) case final maximum?) {
        height = math.min(height, content(maximum));
      }
      if (px(size.minHeight) case final minimum?) {
        height = math.max(height, content(minimum));
      }
    }
    final line = style.rawLine;
    return MeasuredBlock(
      blockId: block.id,
      kind: BlockKind.divider,
      height: height + top + bottom,
      isDecoration: true,
      inset: spacing.left,
      layoutWidth: width,
      box: box,
      // 自身由分隔线绘制入口画完整盒子；祖先继续由 containerBoxes 画，
      // 不再借用祖先 boxId，避免同一条边同时经过两条绘制路径。
      boxId: css ? null : block.boxId,
      containerBoxes: _containerFramesOf(spacing, width),
      bodyTop: top,
      bodyBottom: bottom,
      marginTop: style.marginPixels(
        0,
        lengths.fontSize,
        reference: spacing.containerWidth,
        rootFontSize: lengths.rootFontSize,
      ),
      marginBottom: style.marginPixels(
        2,
        lengths.fontSize,
        reference: spacing.containerWidth,
        rootFontSize: lengths.rootFontSize,
      ),
      line: css || line == null
          ? null
          : [
              (line[0] / 100 * options.settings.fontSize).round(),
              line[1],
              line[2],
            ],
    );
  }
}
