import 'package:flutter/material.dart';

import '../theme/gt_tokens.dart';
import 'gt_button.dart';
import 'gt_icon.dart';

/// 紧凑标题栏使用 36dp 圆形按钮，绘制与触摸区域保持一致。
class GtRoundActionButton extends StatelessWidget {
  const GtRoundActionButton({
    super.key,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.selected = false,
    this.showTooltipOnWindows = true,
  });

  final String tooltip;
  final String icon;
  final VoidCallback onPressed;
  final bool selected;
  final bool showTooltipOnWindows;

  @override
  Widget build(BuildContext context) {
    final colors = context.gtColors;
    return GtButton.icon(
      tooltip: tooltip,
      showTooltipOnWindows: showTooltipOnWindows,
      onPressed: onPressed,
      style: ButtonStyle(
        minimumSize: const WidgetStatePropertyAll(Size.square(36)),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        padding: const WidgetStatePropertyAll(EdgeInsets.zero),
        shape: const WidgetStatePropertyAll(CircleBorder()),
        backgroundColor: WidgetStatePropertyAll(
          selected ? colors.actionPrimary : colors.subtle,
        ),
      ),
      icon: GtIcon(
        icon,
        size: 22,
        color: selected ? Colors.white : colors.textPrimary,
      ),
    );
  }
}
