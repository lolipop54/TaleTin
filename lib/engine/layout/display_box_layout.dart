import 'dart:math' as math;

import 'package:flutter/painting.dart';

import '../styles/computed_style.dart';
import '../styles/style_box_value.dart';
import '../styles/style_table.dart';
import '../styles/style_value.dart';
import 'box_size_resolver.dart';
import 'display_tree.dart';
import 'layout_options.dart';
import 'measured_block.dart';
import 'resolve_block_box.dart';
import 'vertical_margins.dart';

part 'nested_quote_width.dart';

/// 逐层确定内容盒的宽度。作者写出的边框和内边距即便超出可用宽度，也保留原值。
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
    this.marginReference,
    this.containerHeight,
    this.ownerHeight,
    this.margins,
    this.expandQuotes,
  );
  final List<(DisplayContainer, BlockBox)> chain;
  final BlockBox? ownBox;
  final List<ContainerBoxFrame> frames;
  final double width, left, right, top, bottom;
  final double containerWidth;
  final double marginReference;
  final double? containerHeight;
  final BoxAxisSize? ownerHeight;
  final BlockMargins? margins;
  final bool expandQuotes;

  static LengthContext context(
    ComputedStyle style,
    LayoutOptions options,
    double width, {
    bool authorTableCell = false,
  }) {
    final root = options.settings.fontSize.toDouble();
    final size = style.text.fontSize;
    final font = size != null && (size.isRelative || authorTableCell)
        ? size.resolve(parentFontSize: root, rootFontSize: root)
        : root;
    // 历史 pre[width] 给的是字符列数。只在宽度使用 ch 时测一次数字 0。
    double? zero;
    if (style.size.width is ChLength ||
        style.size.minWidth is ChLength ||
        style.size.maxWidth is ChLength) {
      final family = style.text.fontFamilies?.firstOrNull ?? kCodeFontFamily;
      final probe = TextPainter(
        text: TextSpan(
          text: '0',
          style: TextStyle(fontFamily: family, fontSize: font),
        ),
        textScaler: options.textScaler,
        textDirection: TextDirection.ltr,
      )..layout();
      zero = probe.width;
      probe.dispose();
    }
    return LengthContext(
      zeroAdvance: zero,
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
    double? availableHeight,
    double origin = 0,
    bool constrainOwnWidth = true,
    bool ownHeading = false,
    int? blockOwnerId,
    int initialIndentDepth = 0,
    bool expandQuotes = false,
    DisplayTree? tree,
    Map<int, ContainerHeightGeometry>? heightGeometry,
    bool collapseMargins = false,
    double? ownerMarginFontSize,
    ({int elementId, double width})? floatContentWidth,
  }) {
    final page = available ?? options.contentWidth;
    var indentDepth = initialIndentDepth;
    final chain = <(DisplayContainer, BlockBox)>[];
    var left = origin, right = 0.0;
    var top = 0.0, bottom = 0.0;
    double? ownerParentWidth;
    var containerHeight = availableHeight;
    BoxAxisSize? ownerHeight;
    final frames = <ContainerBoxFrame>[];
    final vertical = <VerticalBox>[];
    double px(Length? value, LengthContext context) =>
        value == null || value.isAuto ? 0 : value.resolve(context);
    for (final c in containers) {
      final style = styles?[c.styleId] ?? ComputedStyle.empty;
      final availableWidth = page - (left - origin) - right;
      // 旧 body 页边距加在读者纸面内。章节背景由整页画，这里只处理这四个距离。
      if (c.tag == 'body') {
        final lengths = context(style, options, availableWidth);
        left += px(style.block.margin?.left, lengths);
        right += px(style.block.margin?.right, lengths);
        if (c.first) top += px(style.block.margin?.top, lengths);
        if (c.last) bottom += px(style.block.margin?.bottom, lengths);
        continue;
      }
      if (c.isQuoteOrList) {
        if (c.tag != 'blockquote') {
          expandQuotes = false;
        } else if (indentDepth == 0 && tree != null && styles != null) {
          expandQuotes = _quotesFit(
            tree,
            c.elementId,
            styles,
            options,
            availableWidth,
          );
        }
        indentDepth++;
      }
      final nestedIndent = c.isQuoteOrList && indentDepth > 1 && !expandQuotes;
      final lengths = context(style, options, availableWidth);
      final resolved = resolveBlockBox(style.box, lengths);
      final box = resolved == null || _empty(resolved) ? null : resolved;
      if (c.elementId == blockOwnerId) ownerParentWidth = availableWidth;
      final height = BoxSizeResolver.heightOf(
        lengths,
        style.size,
        box,
        parentHeight: containerHeight,
      );
      containerHeight = height.definite;
      if (c.elementId == blockOwnerId) ownerHeight = height;
      if (collapseMargins) {
        final owner = c.elementId == blockOwnerId;
        vertical.add(
          _verticalBox(
            c.elementId,
            c.first,
            c.last,
            style,
            height,
            owner && ownerMarginFontSize != null
                ? lengths.copyWith(
                    fontSize: ownerMarginFontSize,
                    rootFontSize: options.settings.fontSize.toDouble(),
                  )
                : lengths,
            box,
          ),
        );
      }
      // 例如卷首页和扉页由 div 的百分比外边距定位，不能只读取内边距。
      // 浮动和绝对定位各自计算外边距，空容器也单独处理。
      final usesVerticalMargins =
          !collapseMargins &&
          c.elementId != blockOwnerId &&
          const {
            'div',
            'section',
            'article',
            'figure',
            'header',
            'footer',
          }.contains(c.tag) &&
          (style.block.float == null || style.block.float == FloatSpec.none) &&
          style.block.position != PositionSpec.absolute;
      double margin(Length? length) => length == null || length.isAuto
          ? 0
          : length.resolve(context(style, options, availableWidth));
      if (usesVerticalMargins && c.first) {
        final length = style.block.margin?.top;
        final value = length == null || length.isAuto
            ? 0.0
            : length.resolve(context(style, options, availableWidth));
        top += value;
      }
      // 下外边距和上外边距一样在边框外。记录框的位置前就要扣掉
      // 自己的下外边距，否则它会变成框内的空白。
      if (usesVerticalMargins && c.last) {
        bottom += margin(style.block.margin?.bottom);
      }
      final (marginLeft, contentWidth, marginRight) = _horizontal(
        style,
        options,
        availableWidth,
        box,
        fitToColumn:
            c.role == 'heading' ||
            (style.size.width is PxLength &&
                style.size.height is PxLength &&
                const {'div', 'section', 'article', 'main'}.contains(c.tag) &&
                tree?.nodes[c.elementId].parent?.element.tag == 'body' &&
                style.block.margin?.left?.isAuto == true &&
                style.block.margin?.right?.isAuto == true),
        ignoreHorizontalMargins: nestedIndent,
        rightFloat: c.tag == 'table' && style.block.float == FloatSpec.right,
        contentWidth: c.elementId == floatContentWidth?.elementId
            ? floatContentWidth!.width
            : null,
      );
      left += marginLeft;
      right += marginRight;
      heightGeometry?[c.elementId] = (
        minimum: height.use(0) + (box?.insetTop ?? 0) + (box?.insetBottom ?? 0),
        top: top,
        bottom: bottom,
      );
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
      // 负外边距可以让章题底色铺到纸边。框的位置已记录，框内文字仍在纸栏内断行。
      if (c.role == 'heading') {
        left = math.max(origin, left);
        right = math.max(0.0, right);
      }
    }
    final containerWidth = page - (left - origin) - right;
    var ownBox = ownStyle == null
        ? null
        : resolveBlockBox(
            ownStyle.box,
            context(ownStyle, options, containerWidth),
          );
    if (ownStyle != null && constrainOwnWidth) {
      // 块自己也有 width 和 auto 外边距；此前只约束祖先 div，
      // h1/h2 的短编号背景因此始终铺满整行。
      final (marginLeft, _, marginRight) = _horizontal(
        ownStyle,
        options,
        containerWidth,
        ownBox,
        fitToColumn: ownHeading,
      );
      left += marginLeft;
      right += marginRight;
      if (ownHeading) {
        if (ownBox == null) {
          left = math.max(origin, left);
          right = math.max(0.0, right);
        } else {
          final extraLeft = math.max(0.0, origin - left - ownBox.insetLeft);
          final extraRight = math.max(0.0, -right - ownBox.insetRight);
          if (extraLeft > 0 || extraRight > 0) {
            ownBox = ownBox.withHorizontalPadding(
              ownBox.padLeft + extraLeft,
              ownBox.padRight + extraRight,
            );
          }
        }
      }
    }
    BlockMargins? margins;
    if (collapseMargins) {
      if (ownStyle != null) {
        var lengths = context(ownStyle, options, containerWidth);
        if (ownerMarginFontSize != null) {
          lengths = lengths.copyWith(
            fontSize: ownerMarginFontSize,
            rootFontSize: options.settings.fontSize.toDouble(),
          );
        }
        vertical.add((
          id: -1,
          first: true,
          last: true,
          before: px(ownStyle.block.margin?.top, lengths),
          after: px(ownStyle.block.margin?.bottom, lengths),
          insetTop: 0,
          insetBottom: 0,
          separatesTop: false,
          separatesBottom: false,
        ));
      }
      final leading = layoutVerticalEdge(vertical, leading: true);
      final trailing = layoutVerticalEdge(vertical, leading: false);
      top = leading.inside;
      bottom = trailing.inside;
      margins = BlockMargins(leading.outside, trailing.outside);
      for (final (index, frame) in frames.indexed) {
        frames[index] = ContainerBoxFrame(
          elementId: frame.elementId,
          box: frame.box,
          first: frame.first,
          last: frame.last,
          left: frame.left,
          width: frame.width,
          top: leading.edges[frame.elementId] ?? 0,
          bottom: trailing.edges[frame.elementId] ?? 0,
        );
      }
      if (heightGeometry != null) {
        for (final id in heightGeometry.keys.toList()) {
          final old = heightGeometry[id]!;
          heightGeometry[id] = (
            minimum: old.minimum,
            top: leading.edges[id] ?? 0,
            bottom: trailing.edges[id] ?? 0,
          );
        }
      }
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
      ownerParentWidth ?? containerWidth,
      containerHeight,
      ownerHeight,
      margins,
      expandQuotes,
    );
  }

  static VerticalBox _verticalBox(
    int id,
    bool first,
    bool last,
    ComputedStyle style,
    BoxAxisSize height,
    LengthContext lengths,
    BlockBox? box,
  ) {
    double px(Length? value) =>
        value == null || value.isAuto ? 0 : value.resolve(lengths);
    final separates = establishesBlockContext(style);
    return (
      id: id,
      first: first,
      last: last,
      before: px(style.block.margin?.top),
      after: px(style.block.margin?.bottom),
      insetTop: box?.insetTop ?? 0,
      insetBottom: box?.insetBottom ?? 0,
      separatesTop: separates,
      separatesBottom:
          separates || height.preferred != null || height.lower > 0,
    );
  }

  static bool establishesBlockContext(ComputedStyle style) =>
      const {
        DisplaySpec.flowRoot,
        DisplaySpec.flex,
        DisplaySpec.grid,
        DisplaySpec.inlineBlock,
        DisplaySpec.table,
        DisplaySpec.tableCell,
      }.contains(style.block.display) ||
      (style.box.overflow != null &&
          style.box.overflow != 'visible' &&
          style.box.overflow != 'clip');

  /// 表格先按声明的宽度占位，等列宽和表题确定后，按同一套外边距规则移动整张表。
  static double tableWidthOffset(
    ComputedStyle style,
    LayoutOptions options,
    double parentWidth,
    BlockBox? box, {
    required double initialWidth,
    required double finalWidth,
  }) {
    final rightFloat = style.block.float == FloatSpec.right;
    if (initialWidth == finalWidth ||
        (!rightFloat &&
            style.block.margin?.left?.isAuto != true &&
            style.block.position != PositionSpec.absolute)) {
      return 0;
    }
    double leftAt(double width) => _horizontal(
      style,
      options,
      parentWidth,
      box,
      contentWidth: width,
      rightFloat: rightFloat,
    ).$1;
    return leftAt(finalWidth) - leftAt(initialWidth);
  }

  /// 已指定宽度的块先按父内容区求宽度，再分配水平外边距。图片的 100%
  /// 随后参照这个内容宽度，不参照纸面；源图分辨率不会改变包含块尺寸。
  static (double, double, double) _horizontal(
    ComputedStyle style,
    LayoutOptions options,
    double available,
    BlockBox? box, {
    bool ignoreHorizontalMargins = false,
    bool fitToColumn = false,
    bool rightFloat = false,
    double? contentWidth,
  }) {
    final ctx = context(style, options, available);
    double? px(Length? value) =>
        value == null || value.isAuto ? null : value.resolve(ctx);
    final padding = (box?.insetLeft ?? 0) + (box?.insetRight ?? 0);
    // 指定尺寸按作者的 box-sizing 换算。负外边距是盒子位移，
    // 绘制越出纸面的部分在当前页裁掉。
    final margin = ignoreHorizontalMargins ? null : style.block.margin;
    var left = px(margin?.left) ?? 0.0;
    final right = px(margin?.right) ?? 0.0;
    var width =
        contentWidth ??
        math.max(
          0.0,
          BoxSizeResolver.widthOf(
            ctx,
            style.size,
            box,
          ).use(available - padding - left - right),
        );
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
      return (
        positionedLeft,
        width,
        available - positionedLeft - width - padding,
      );
    }
    final centered =
        margin?.left?.isAuto == true && margin?.right?.isAuto == true;
    // 章题和整张扉页的外框可能比一栏宽。先为外边距、内边距和边线留位，
    // 再收窄内容区，这样文字换行、靠右或居中都使用同一条边缘。
    if (fitToColumn &&
        (style.block.float == null || style.block.float == FloatSpec.none) &&
        (style.block.position == null ||
            style.block.position == PositionSpec.static ||
            style.block.position == PositionSpec.relative)) {
      width = math.min(
        width,
        math.max(0.0, available - padding - left - right),
      );
    }
    final free = available - width - padding;
    final autoSpace = math.max(0.0, free - left - right);
    if (rightFloat) {
      left += autoSpace;
    } else if (centered) {
      left = autoSpace / 2;
    } else if (margin?.left?.isAuto == true) {
      left = autoSpace;
    }
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
}

typedef ContainerHeightGeometry = ({double minimum, double top, double bottom});
