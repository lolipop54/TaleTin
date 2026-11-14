import 'dart:math' as math;

import '../styles/computed_style.dart';
import '../styles/style_box_value.dart';
import '../styles/style_table.dart';
import '../styles/style_value.dart';
import 'display_tree.dart';
import 'layout_options.dart';
import 'measured_block.dart';
import 'resolve_block_box.dart';

/// 正文、图片、表格和空元素共用的容器约束。所有层先解析，再统一分配
/// 横向空间；深层缩进最多使用纸面宽度的 3/4，始终保留可读正文宽度。
class DisplayBoxLayout {
  DisplayBoxLayout(
    this.chain,
    this.ownBox,
    this.frames,
    this.width,
    this.left,
    this.right,
    this.top,
    this.bottom,
    this.containerWidth,
  );
  final List<(DisplayContainer, BlockBox)> chain;
  final BlockBox? ownBox;
  final List<ContainerBoxFrame> frames;
  final double width, left, right, top, bottom;
  final double containerWidth;

  static LengthContext context(
    ComputedStyle style,
    LayoutOptions options,
    double width,
  ) {
    final root = options.settings.fontSize.toDouble();
    final font = style.text.fontSize?.isRelative == true
        ? style.text.fontSize!.resolve(parentFontSize: root, rootFontSize: root)
        : root;
    return LengthContext(
      fontSize: options.textScaler.scale(font),
      rootFontSize: options.textScaler.scale(root),
      reference: width,
      viewportWidth: options.contentWidth,
      viewportHeight: options.contentHeight,
    );
  }

  static DisplayBoxLayout resolve(
    List<DisplayContainer> containers,
    StyleTable? styles,
    LayoutOptions options, {
    ComputedStyle? ownStyle,
    double? available,
    double origin = 0,
    bool constrainOwnWidth = true,
    bool ownHeading = false,
    int initialIndentDepth = 0,
    ({int parentId, double left, double right})? floatInsets,
  }) {
    final page = available ?? options.contentWidth;
    final raw = <(DisplayContainer, BlockBox?, ComputedStyle, bool)>[];
    final rootFloat =
        floatInsets != null &&
        !containers.any((c) => c.elementId == floatInsets.parentId);
    var reference = rootFloat
        ? page - floatInsets.left - floatInsets.right
        : page;
    var indentDepth = initialIndentDepth;
    for (final c in containers) {
      // 与原书阅读共用产品规则：引用/列表第二层起不再增加左右外边距。
      // 只抑制重复的缩进；每层背景、padding、边框和真实宽度仍照常计算。
      if (c.isQuoteOrList) indentDepth++;
      final nestedIndent = c.isQuoteOrList && indentDepth > 1;
      final style = styles?[c.styleId] ?? ComputedStyle.empty;
      final box = resolveBlockBox(
        style.box,
        context(style, options, reference),
      );
      final visibleBox = box == null || _empty(box) ? null : box;
      // 只有宽度、没有底色和边框的 div 也是实际包含块，不能跳过。
      raw.add((c, visibleBox, style, nestedIndent));
      reference = _horizontal(
        style,
        options,
        reference,
        visibleBox,
        heading: c.role == 'heading',
        ignoreHorizontalMargins: nestedIndent,
      ).$2;
      if (c.elementId == floatInsets?.parentId) {
        reference -= floatInsets!.left + floatInsets.right;
      }
    }
    final own = ownStyle == null
        ? null
        : resolveBlockBox(ownStyle.box, context(ownStyle, options, reference));
    final total =
        raw.fold(
          0.0,
          (n, e) => n + (e.$2?.insetLeft ?? 0) + (e.$2?.insetRight ?? 0),
        ) +
        (own?.insetLeft ?? 0) +
        (own?.insetRight ?? 0);
    final factor = total > page * .75 ? page * .75 / total : 1.0;
    final chain = <(DisplayContainer, BlockBox)>[];
    final ownBox = own == null ? null : _fit(own, factor);
    var left = origin + (rootFloat ? floatInsets.left : 0.0);
    var right = rootFloat ? floatInsets.right : 0.0;
    var top = 0.0, bottom = 0.0;
    final frames = <ContainerBoxFrame>[];
    for (final (c, originalBox, style, nestedIndent) in raw) {
      final box = originalBox == null ? null : _fit(originalBox, factor);
      final availableWidth = page - (left - origin) - right;
      final (marginLeft, contentWidth, marginRight) = _horizontal(
        style,
        options,
        availableWidth,
        box,
        heading: c.role == 'heading',
        ignoreHorizontalMargins: nestedIndent,
      );
      left += marginLeft;
      right += marginRight;
      if (box != null) {
        chain.add((c, box));
        // 内层框从外层内容区开始；上下同样累计，不能只算横向位置。
        frames.add(
          ContainerBoxFrame(
            elementId: c.elementId,
            box: box,
            first: c.first,
            last: c.last,
            left: left,
            width: contentWidth + box.insetLeft + box.insetRight,
            top: top,
            bottom: bottom,
          ),
        );
        left += box.insetLeft;
        right += box.insetRight;
        if (c.first) top += box.insetTop;
        if (c.last) bottom += box.insetBottom;
      }
      if (c.elementId == floatInsets?.parentId) {
        left += floatInsets!.left;
        right += floatInsets.right;
      }
    }
    final containerWidth = page - (left - origin) - right;
    if (ownStyle != null && constrainOwnWidth) {
      // 块自己也有 width 和 auto 外边距；此前只约束祖先 div，
      // h1/h2 的短编号背景因此始终铺满整行。
      final (marginLeft, _, marginRight) = _horizontal(
        ownStyle,
        options,
        containerWidth,
        ownBox,
        heading: ownHeading,
      );
      left += marginLeft;
      right += marginRight;
    }
    return DisplayBoxLayout(
      chain,
      ownBox,
      frames,
      page - (left - origin) - right,
      left,
      right,
      top,
      bottom,
      containerWidth,
    );
  }

  /// 已指定宽度的块先按父内容区求宽度，再分配水平外边距。图片的 100%
  /// 随后参照这个内容宽度，不参照纸面；源图分辨率不会改变包含块尺寸。
  static (double, double, double) _horizontal(
    ComputedStyle style,
    LayoutOptions options,
    double available,
    BlockBox? box, {
    bool heading = false,
    bool ignoreHorizontalMargins = false,
  }) {
    final ctx = context(style, options, available);
    double? px(Length? value) =>
        value == null || value.isAuto ? null : value.resolve(ctx);
    final padding = (box?.insetLeft ?? 0) + (box?.insetRight ?? 0);
    final size = style.size;
    final explicit = px(size.width);
    final minimum = px(size.minWidth);
    final maximum = px(size.maxWidth);
    // 与原书阅读的标题约束一致：标题宽度包含边框与内边距，
    // 并限制在正文区内；书里的负边距不把背景推出纸面。
    final borderBox = heading || size.boxSizing == BoxSizingSpec.borderBox;
    final margin = ignoreHorizontalMargins ? null : style.block.margin;
    var left = math.max(0.0, px(margin?.left) ?? 0);
    final right = math.max(0.0, px(margin?.right) ?? 0);
    double content(double width) => borderBox ? width - padding : width;
    var width = explicit == null
        ? available - padding - left - right
        : content(explicit);
    if (maximum != null) width = math.min(width, content(maximum));
    if (minimum != null) width = math.max(width, content(minimum));
    width = width.clamp(1.0, math.max(1.0, available - padding));
    if (style.block.position == PositionSpec.absolute) {
      final start = px(style.block.inset?.left);
      final end = px(style.block.inset?.right);
      final rawLeft = px(margin?.left) ?? 0.0;
      final rawRight = px(margin?.right) ?? 0.0;
      // 百分比 left 与负 margin 常配合居中。它们是同一定位计算，
      // 不能只丢掉负 margin，再把出版社推向左侧。
      final positionedLeft = start != null
          ? start + rawLeft
          : end != null
          ? available - end - rawRight - width - padding
          : rawLeft;
      final fittedLeft = positionedLeft
          .clamp(0.0, math.max(0.0, available - width - padding))
          .toDouble();
      return (
        fittedLeft,
        width,
        math.max(0.0, available - fittedLeft - width - padding),
      );
    }
    final free = math.max(0.0, available - width - padding);
    final autoSpace = math.max(0.0, free - left - right);
    if (margin?.left?.isAuto == true && margin?.right?.isAuto == true) {
      left = autoSpace / 2;
    } else if (margin?.left?.isAuto == true) {
      left = autoSpace;
    }
    left = math.min(left, free);
    // 未分给左边的剩余宽度留在右边；不把它再当成子元素内容区。
    return (left, width, free - left);
  }

  static bool _empty(BlockBox box) =>
      box.insetLeft == 0 &&
      box.insetRight == 0 &&
      box.insetTop == 0 &&
      box.insetBottom == 0 &&
      box.background == null &&
      box.backgroundImage == null &&
      box.radius == 0 &&
      box.shadows.isEmpty;

  static BlockBox _fit(BlockBox box, double factor) => factor == 1
      ? box
      : BlockBox(
          background: box.background,
          backgroundImage: box.backgroundImage,
          borderColors: box.borderColors,
          borderTop: box.borderTop,
          borderRight: box.borderRight * factor,
          borderBottom: box.borderBottom,
          borderLeft: box.borderLeft * factor,
          borderStyles: box.borderStyles,
          borderRadius: box.borderRadius,
          shadows: box.shadows,
          padTop: box.padTop,
          padRight: box.padRight * factor,
          padBottom: box.padBottom,
          padLeft: box.padLeft * factor,
        );
}
