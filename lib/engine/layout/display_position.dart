import 'dart:math' as math;

import '../styles/computed_style.dart';
import '../styles/style_box_value.dart';
import '../styles/style_value.dart';
import '../styles/style_table.dart';
import 'display_box_layout.dart';
import 'display_tree.dart';
import 'layout_options.dart';

/// 重排页面中的纵向锚点。百分比以阅读内容区高度为准，而不是 CSS 边距使用的
/// 宽度。先量出内容高度，再从底部反推顶部，分页、滚动和恢复共用此结果。
abstract final class DisplayPosition {
  static double? topOf(
    ComputedStyle style,
    LayoutOptions options,
    double height, {
    DisplayTree? tree,
    int? index,
    StyleTable? styles,
  }) {
    final source = tree?.source;
    final owner = index == null ? null : source?.ownerOfBlock(index);
    // 一个绝对定位 div 可以包含书名、作者等多块正文；只在首块应用
    // 组的纵向起点，后续块沿用正常流。不能因为 div 不只一块就丢掉 top。
    var positioned = owner;
    if (owner != null && style.block.position != PositionSpec.absolute) {
      while (positioned != null &&
          styles?[positioned.styleId ?? 0].block.position !=
              PositionSpec.absolute) {
        positioned = source!.element(positioned.parent ?? -1);
      }
      if (positioned == null || positioned.firstBlock != index) return null;
      style = styles![positioned.styleId ?? 0];
    }
    if (style.block.position != PositionSpec.absolute) return null;
    if (owner != null) {
      var parent = (positioned ?? owner).parent;
      while (parent != null) {
        final element = source!.element(parent)!;
        final position = styles?[element.styleId ?? 0].block.position;
        if (position != null && position != PositionSpec.static) return null;
        parent = element.parent;
      }
    }
    final insets = style.block.inset;
    if (insets == null) return null;
    final c = DisplayBoxLayout.context(style, options, options.contentWidth);
    final context = LengthContext(
      fontSize: c.fontSize,
      rootFontSize: c.rootFontSize,
      reference: options.contentHeight,
      viewportWidth: options.contentWidth,
      viewportHeight: options.contentHeight,
    );
    final top = insets.top;
    final bottom = insets.bottom;
    final margin = style.block.margin?.top;
    final topMargin = margin == null || margin.isAuto ? 0 : margin.resolve(c);
    final specifiedHeight = style.size.height;
    final boxHeight = specifiedHeight == null || specifiedHeight.isAuto
        ? height
        : math.max(height, specifiedHeight.resolve(context));
    // margin-top 的百分比按包含块宽度；top/bottom 的百分比才按页高。
    final target = top != null && !top.isAuto
        ? top.resolve(context) + topMargin
        : bottom != null && !bottom.isAuto
        ? options.contentHeight - bottom.resolve(context) - boxHeight
        : null;
    // 过大字号或小窗口仍以可阅读为先，内容不越出纸面，也不遮盖前文。
    return target?.clamp(0.0, math.max(0.0, options.contentHeight - height));
  }
}
