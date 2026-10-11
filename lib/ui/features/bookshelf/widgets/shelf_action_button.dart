import 'package:flutter/material.dart';

import '../../../core/theme/gt_tokens.dart';
import '../../../core/widgets/gt_button.dart';
import '../../../core/widgets/gt_icon.dart';

/// 书架顶部使用 36dp 圆形按钮，绘制与触摸区域保持一致。
class ShelfActionButton extends StatelessWidget {
  const ShelfActionButton({
    super.key,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.selected = false,
  });

  final String tooltip;
  final String icon;
  final VoidCallback onPressed;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final colors = context.gtColors;
    return GtButton.icon(
      tooltip: tooltip,
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
