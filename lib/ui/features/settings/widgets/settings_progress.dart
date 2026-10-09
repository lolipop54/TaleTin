import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/theme/gt_tokens.dart';

/// 只显示服务报告的完成比例；尚无总量时保持空轨道，不模拟进度。
class SettingsProgress extends StatelessWidget {
  const SettingsProgress({super.key, required this.label, this.fraction});
  final String label;
  final double? fraction;
  @override
  Widget build(BuildContext context) {
    final c = context.gtColors;
    final value = fraction?.clamp(0.0, 1.0);
    return Semantics(
      label: label,
      value: value == null ? null : '${(value * 100).round()}%',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(label, style: GtText.caption(c.textSecondary)),
              ),
              if (value != null)
                Text(
                  '${(value * 100).round()}%',
                  style: GtText.caption(c.textSecondary),
                ),
            ],
          ),
          const SizedBox(height: 8),
          ExcludeSemantics(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: value ?? 0,
                minHeight: 4,
                backgroundColor: c.subtle,
                color: c.actionPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
