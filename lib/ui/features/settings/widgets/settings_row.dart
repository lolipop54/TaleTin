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
    this.subtitle,
    this.trailing,
    this.onTap,
    this.divider = true,
    this.wrapValue = false,
  });

  final String label;
  final String? value;
  final String? subtitle;
  final Widget? trailing;

  final VoidCallback? onTap;
  final bool divider;

  /// 桌面分类卡里的长值优先分配宽度，窄窗或大字号允许换行。
  final bool wrapValue;

  @override
  Widget build(BuildContext context) {
    final colors = context.gtColors;
    final row = Container(
      constraints: const BoxConstraints(minHeight: 48),
      decoration: divider
          ? BoxDecoration(
              border: Border(bottom: BorderSide(color: colors.borderSubtle)),
            )
          : null,
      child: Row(
        children: [
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: GtText.body(colors.textPrimary).copyWith(fontSize: 14),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(subtitle!, style: GtText.caption(colors.textSecondary)),
                ],
              ],
            ),
          ),
          const SizedBox(width: GtSpacing.s3),
          if (trailing != null)
            trailing!
          else ...[
            if (value != null)
              Flexible(
                flex: wrapValue ? 3 : 1,
                fit: FlexFit.tight,
                child: Text(
                  value ?? '',
                  textAlign: TextAlign.right,
                  maxLines: wrapValue ? null : 1,
                  overflow: wrapValue
                      ? TextOverflow.clip
                      : TextOverflow.ellipsis,
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
    );
    // 只有整行可点击时才给行加按钮，避免子控件获焦时整行也画焦点框。
    return onTap == null ? row : GtButton.raw(onPressed: onTap, child: row);
  }
}
