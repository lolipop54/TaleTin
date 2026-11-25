import 'dart:math' as math;

import '../styles/computed_style.dart';
import '../styles/style_box_value.dart';
import '../styles/style_table.dart';
import 'display_box_layout.dart';
import 'box_size_resolver.dart';
import 'resolve_block_box.dart';
import 'display_tree.dart';
import 'layout_options.dart';

/// 分页和滚动共用同一坐标。页面装饰图以单页定位；容器内装饰图以父框定位。
abstract final class DisplayPosition {
  /// 起边优先。定位量用本轴长度，四边 margin 的百分比都用包含块宽度。
  static double? offset(
    ComputedStyle style,
    LayoutOptions options,
    double width,
    double height,
    double extent, {
    required bool vertical,
  }) {
    final lengths = DisplayBoxLayout.context(style, options, width);
    final inset = style.block.inset?.resolve(
      vertical ? lengths.copyWith(reference: height) : lengths,
    );
    final margin = style.block.margin?.resolve(lengths);
    final start = vertical ? inset?.top : inset?.left;
    final end = vertical ? inset?.bottom : inset?.right;
    if (start != null) {
      return start + ((vertical ? margin?.top : margin?.left) ?? 0);
    }
    if (end == null) return null;
    return (vertical ? height : width) -
        end -
        extent -
        ((vertical ? margin?.bottom : margin?.right) ?? 0);
  }

  /// 紧贴纸面的独立图片使用该页坐标，不参与正文的上下排列。
  static bool isPageImage(ComputedStyle style, DisplayTree? tree, int? index) {
    if (index == null || style.block.position != PositionSpec.absolute) {
      return false;
    }
    final source = tree?.source;
    final image = source?.ownerOfBlock(index);
    if (image?.tag != 'img') return false;
    final parent = source?.element(image?.parent ?? -1);
    final inset = style.block.inset;
    return (parent?.tag == 'body' || parent?.tag == 'html') &&
        (inset?.top?.isAuto == false || inset?.bottom?.isAuto == false) &&
        (inset?.left?.isAuto == false || inset?.right?.isAuto == false);
  }

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
    if (owner != null && !isPageImage(style, tree, index)) {
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
    final box = resolveBlockBox(style.box, c);
    final vertical = (box?.insetTop ?? 0) + (box?.insetBottom ?? 0);
    final preferred = BoxSizeResolver.heightOf(
      c,
      style.size,
      box,
      parentHeight: options.contentHeight,
    ).definite;
    final boxHeight = preferred == null ? height : preferred + vertical;
    // margin-top 的百分比按包含块宽度；top/bottom 的百分比才按页高。
    final target = offset(
      style,
      options,
      options.contentWidth,
      options.contentHeight,
      boxHeight,
      vertical: true,
    );
    if (isPageImage(style, tree, index)) return target;
    // 过大字号或小窗口仍以可阅读为先，内容不越出纸面，也不遮盖前文。
    return target?.clamp(0.0, math.max(0.0, options.contentHeight - height));
  }
}
