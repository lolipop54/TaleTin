import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/theme/gt_tokens.dart';
import '../../../core/widgets/decorations.dart';

/// 两端共用设置页的题字和落款，标题字号跟随各自的布局。
class SettingsHeader extends StatelessWidget {
  const SettingsHeader({super.key, required this.titleSize});

  final double titleSize;

  @override
  Widget build(BuildContext context) {
    final colors = context.gtColors;
    final caption = GtText.caption(colors.textSecondary)
        .copyWith(fontSize: 11, height: 1.7);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              FoldCornerHeading(
                '设置',
                pageTitle: true,
                style: GtText.pageTitle(colors.textPrimary)
                    .copyWith(fontSize: titleSize),
              ),
              const SizedBox(height: GtSpacing.s1),
              Text(
                '阅读，让生活更柔软。',
                style: GtText.body(colors.textSecondary)
                    .copyWith(fontSize: 14, letterSpacing: 1),
              ),
            ],
          ),
        ),
        const SizedBox(width: GtSpacing.s3),
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text('书中自有', style: caption),
            Text('向上的光', style: caption),
            const SizedBox(height: GtSpacing.s2),
            Container(width: 18, height: 1, color: colors.borderControl),
          ],
        ),
      ],
    );
  }
}
