import 'package:flutter/material.dart';
import 'package:forui/forui.dart';

import 'gt_button_tap_area.dart';

/// 保留项目原有按钮尺寸和样式，点击、焦点与禁用行为交给 Forui。
/// ButtonStyle 只作为旧页面已有颜色/圆角的输入，不再创建 Material 按钮。
class GtButton extends StatelessWidget {
  const GtButton({
    super.key,
    required this.onPressed,
    required this.child,
    this.style,
    this.tooltip,
    this.variant = FButtonVariant.ghost,
  }) : iconOnly = false,
       raw = false,
       selected = false,
       borderRadius = null,
       customBorder = null,
       onLongPress = null;
  const GtButton.filled({
    Key? key,
    required VoidCallback? onPressed,
    required Widget child,
    ButtonStyle? style,
  }) : this(
         key: key,
         onPressed: onPressed,
         child: child,
         style: style,
         variant: FButtonVariant.primary,
       );
  const GtButton.outlined({
    Key? key,
    required VoidCallback? onPressed,
    required Widget child,
    ButtonStyle? style,
  }) : this(
         key: key,
         onPressed: onPressed,
         child: child,
         style: style,
         variant: FButtonVariant.outline,
       );
  const GtButton.tonal({
    Key? key,
    required VoidCallback? onPressed,
    required Widget child,
    ButtonStyle? style,
  }) : this(
         key: key,
         onPressed: onPressed,
         child: child,
         style: style,
         variant: FButtonVariant.secondary,
       );
  GtButton.label({
    Key? key,
    required VoidCallback? onPressed,
    required Widget icon,
    required Widget label,
    ButtonStyle? style,
  }) : this(
         key: key,
         onPressed: onPressed,
         style: style,
         child: Row(
           mainAxisSize: MainAxisSize.min,
           children: [
             icon,
             const SizedBox(width: 8),
             Flexible(child: label),
           ],
         ),
       );
  const GtButton.icon({
    super.key,
    required this.onPressed,
    required Widget icon,
    this.style,
    this.tooltip,
  }) : child = icon,
       iconOnly = true,
       raw = false,
       selected = false,
       borderRadius = null,
       customBorder = null,
       onLongPress = null,
       variant = FButtonVariant.ghost;

  /// 已自行绘制的工具栏/卡片按钮只替换点击控件，不改变其内容布局。
  const GtButton.raw({
    super.key,
    required this.onPressed,
    required this.child,
    this.tooltip,
    this.selected = false,
    this.borderRadius,
    this.customBorder,
    this.onLongPress,
  }) : style = null,
       iconOnly = false,
       raw = true,
       variant = FButtonVariant.ghost;

  /// 卡片、列表里的小号文字按钮（如笔记条目的“编辑/删除/跳转”）。
  /// 默认按钮按 Material 规范会保留至少 64×48 的触摸容器，12 号文字套进去后
  /// 比文字本身大出一圈，还会把行高撑到 48dp，相邻按钮之间容易互相误触。
  /// 传这个样式后按钮只占“文字 + 下面的 padding”，想调大就改这里的内边距
  /// （vertical 每加 2dp，按钮高 2dp）。仅用于紧邻的小按钮；一般独立按钮仍保留
  /// 48dp 触摸目标（工具栏图标见 [compactIconStyle]）。
  static const ButtonStyle compactStyle = ButtonStyle(
    minimumSize: WidgetStatePropertyAll(Size.zero),
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    padding: WidgetStatePropertyAll(
      EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    ),
  );

  /// 工具栏图标按钮（如阅读页顶部栏的书签、全文搜索、已读）。
  /// 默认图标按钮的触摸容器是 48×48，比图标本身大一圈；工具栏一行里并排放几个时
  /// 显得空、也容易误触。传这个样式后触摸范围就是下面的 minimumSize
  /// （当前 42×42），图标尺寸不变、居中显示。
  static const ButtonStyle compactIconStyle = ButtonStyle(
    minimumSize: WidgetStatePropertyAll(Size(42, 42)),
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    padding: WidgetStatePropertyAll(EdgeInsets.zero),
  );

  final VoidCallback? onPressed;
  final Widget child;
  final ButtonStyle? style;
  final String? tooltip;
  final FButtonVariant variant;
  final bool iconOnly, raw;
  final bool selected;
  final BorderRadius? borderRadius;
  final ShapeBorder? customBorder;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final filled = variant == FButtonVariant.primary;
    final tonal = variant == FButtonVariant.secondary;
    final outline = variant == FButtonVariant.outline;
    final defaults = iconOnly
        ? theme.iconButtonTheme.style
        : filled || tonal
        ? theme.filledButtonTheme.style
        : outline
        ? theme.outlinedButtonTheme.style
        : theme.textButtonTheme.style;
    final effective = defaults?.merge(style) ?? style;
    final states = <WidgetState>{if (onPressed == null) WidgetState.disabled};
    final foreground =
        effective?.foregroundColor?.resolve(states) ??
        (onPressed == null
            ? scheme.onSurface.withValues(alpha: 0.38)
            : filled
            ? scheme.onPrimary
            : tonal
            ? scheme.onSecondaryContainer
            : iconOnly
            ? scheme.onSurfaceVariant
            : scheme.primary);
    final background =
        effective?.backgroundColor?.resolve(states) ??
        (filled || tonal
            ? onPressed == null
                  ? scheme.onSurface.withValues(alpha: 0.12)
                  : filled
                  ? scheme.primary
                  : scheme.secondaryContainer
            : Colors.transparent);
    final shape = effective?.shape?.resolve(states) ?? const StadiumBorder();
    final side =
        effective?.side?.resolve(states) ??
        (outline
            ? BorderSide(
                color: onPressed == null
                    ? scheme.onSurface.withValues(alpha: 0.12)
                    : scheme.outline,
              )
            : BorderSide.none);
    final decoration = raw
        ? customBorder != null
              ? ShapeDecoration(shape: customBorder!, color: Colors.transparent)
              : BoxDecoration(borderRadius: borderRadius)
        : ShapeDecoration(
            color: background,
            shape: shape.copyWith(side: side),
          );
    final requestedSize =
        effective?.minimumSize?.resolve(states) ??
        (iconOnly ? const Size(40, 40) : const Size(64, 40));
    // Material 的默认触摸容器至少 48dp；保留这一尺寸，避免换组件后行距变窄。
    final padded =
        (effective?.tapTargetSize ?? theme.materialTapTargetSize) ==
        MaterialTapTargetSize.padded;
    final minSize = Size(
      padded
          ? requestedSize.width.clamp(48, double.infinity)
          : requestedSize.width,
      padded
          ? requestedSize.height.clamp(48, double.infinity)
          : requestedSize.height,
    );
    final padding =
        effective?.padding?.resolve(states) ??
        EdgeInsets.symmetric(
          horizontal: iconOnly
              ? 8
              : filled || tonal || outline
              ? 24
              : 12,
          vertical: 8,
        );
    final FVariants<
      FTappableVariantConstraint,
      FTappableVariant,
      Decoration,
      DecorationDelta
    >
    decorations = FVariants.from(
      decoration,
      variants: {
        if (!raw && onPressed != null)
          [FTappableVariant.pressed]: DecorationDelta.shapeDelta(
            color: Color.alphaBlend(
              foreground.withValues(alpha: 0.08),
              background,
            ),
          ),
      },
    );
    Widget content = raw
        ? child
        : ConstrainedBox(
            constraints: BoxConstraints(
              minWidth: requestedSize.width,
              minHeight: requestedSize.height,
            ),
            child: Padding(
              padding: padding,
              child: Center(
                widthFactor: 1,
                heightFactor: 1,
                child: DefaultTextStyle.merge(
                  style:
                      (effective?.textStyle?.resolve(states) ??
                              theme.textTheme.labelLarge!)
                          .copyWith(color: foreground),
                  child: IconTheme.merge(
                    data: IconThemeData(color: foreground, size: 24),
                    child: child,
                  ),
                ),
              ),
            ),
          );
    if (!raw) {
      final surface = content;
      // 外层负责完整触摸范围，内层保留原按钮实际绘制高度和圆角。
      // 用 Forui 当前交互状态绘制内层底色，不改变按钮绘制尺寸。
      content = GtButtonTapArea(
        minimumSize: minSize,
        child: Builder(
          builder: (context) => DecoratedBox(
            decoration: decorations.resolve(FButtonData.of(context).variants),
            child: surface,
          ),
        ),
      );
    }
    content = FButton.raw(
      variant: variant,
      onPress: onPressed,
      onLongPress: onLongPress,
      selected: selected,
      semanticsLabel: iconOnly ? tooltip : null,
      style: FButtonStyleDelta.delta(
        // 所有项目按钮共用这一入口；关闭缩放，保留底色、焦点与禁用反馈。
        tappableStyle: const FTappableStyleDelta.delta(
          motion: FTappableMotion.none,
        ),
        decoration: raw ? decorations : const FVariants.all(BoxDecoration()),
      ),
      child: content,
    );
    if (tooltip != null) {
      content = Tooltip(
        message: tooltip!,
        triggerMode: TooltipTriggerMode.longPress,
        child: content,
      );
    }
    return content;
  }
}
