import 'package:flutter/material.dart';

import '../theme/gt_tokens.dart';
import 'gt_button.dart';

/// 依据实际操作指定颜色，不从“确定”等按钮文案猜测是否会删除数据。
enum GtDialogActionRole { primary, danger, neutral }

/// 对话框操作共用主题颜色；保留原有实心／文字按钮形式和禁用反馈。
class GtDialogAction extends StatelessWidget {
  const GtDialogAction({
    super.key,
    required this.label,
    required this.onPressed,
    this.role = GtDialogActionRole.neutral,
    this.filled = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final GtDialogActionRole role;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final colors = context.gtColors;
    final color = switch (role) {
      GtDialogActionRole.primary => colors.actionPrimary,
      GtDialogActionRole.danger => colors.danger,
      GtDialogActionRole.neutral => colors.textPrimary,
    };
    final style = TextButton.styleFrom(
      foregroundColor: filled ? colors.onPrimary : color,
      backgroundColor: filled ? color : null,
      disabledForegroundColor: colors.textMuted,
      disabledBackgroundColor: filled ? colors.subtle : null,
    );
    return filled
        ? GtButton.filled(
            onPressed: onPressed,
            style: style,
            child: Text(label),
          )
        : GtButton(onPressed: onPressed, style: style, child: Text(label));
  }
}
