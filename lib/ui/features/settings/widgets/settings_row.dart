import 'package:taletin/ui/core/widgets/gt_button.dart';
import 'package:flutter/material.dart';

import '../../../core/theme/gt_tokens.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/gt_icon.dart';

/// 名称靠左、值或开关靠右；普通字号统一 48dp，大字号允许自然增高。
class SettingsRow extends StatelessWidget {
  const SettingsRow({
    super.key,
    required this.label,
    this.value,
    this.trailing,
    this.onTap,
    this.divider = true,
  });

  final String label;
  final String? value;
  final Widget? trailing;

  final VoidCallback? onTap;
  final bool divider;

  @override
  Widget build(BuildContext context) {
    final colors = context.gtColors;
    return GtButton.raw(
      onPressed: onTap,
      child: Container(
        constraints: const BoxConstraints(minHeight: 48),
        decoration: divider
            ? BoxDecoration(
                border: Border(bottom: BorderSide(color: colors.borderSubtle)),
              )
            : null,
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: GtText.body(colors.textPrimary).copyWith(fontSize: 14),
              ),
            ),
            const SizedBox(width: GtSpacing.s3),
            if (trailing != null)
              trailing!
            else ...[
              if (value != null)
                Flexible(
                  fit: FlexFit.tight,
                  child: Text(
                    value ?? '',
                    textAlign: TextAlign.right,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GtText.caption(colors.textSecondary)
                        .copyWith(fontSize: 12),
                  ),
                ),
              const SizedBox(width: GtSpacing.s1),
              if (onTap != null)
                GtIcon(GtIcons.chevronRight, size: 20, color: colors.textMuted),
            ],
          ],
        ),
      ),
    );
  }
}
