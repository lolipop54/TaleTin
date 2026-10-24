import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/theme/gt_tokens.dart';
import '../../../core/widgets/gt_button.dart';

class LocalFileBar extends StatelessWidget {
  const LocalFileBar({
    super.key,
    required this.count,
    required this.busy,
    required this.onAll,
    required this.onDelete,
    required this.onImport,
    this.allSelected = false,
    this.importLabel = '加入书架',
  });
  final int count;
  final bool busy;
  final bool allSelected;
  final VoidCallback onAll, onImport;
  final VoidCallback? onDelete;
  final String importLabel;
  @override
  Widget build(BuildContext context) {
    final colors = context.gtColors;
    return Container(
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(top: BorderSide(color: colors.borderSubtle)),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            const SizedBox(width: GtSpacing.s5),
            Text.rich(
              TextSpan(
                children: [
                  const TextSpan(text: '已选 '),
                  TextSpan(
                    text: '$count',
                    style: TextStyle(color: colors.actionPrimary),
                  ),
                  const TextSpan(text: ' 项'),
                ],
              ),
              style: GtText.body(colors.textPrimary),
            ),
            const Spacer(),
            GtButton(
              onPressed: busy ? null : onAll,
              style: TextButton.styleFrom(
                foregroundColor: colors.textPrimary,
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
              child: Text(allSelected ? '取消全选' : '全选'),
            ),
            if (onDelete != null)
              GtButton(
                onPressed: busy || count == 0 ? null : onDelete,
                style: TextButton.styleFrom(
                  foregroundColor: colors.textPrimary,
                ),
                child: const Text('删除'),
              ),
            GtButton.filled(
              onPressed: busy || count == 0 ? null : onImport,
              style: FilledButton.styleFrom(
                minimumSize: const Size(0, GtSize.touchMin),
                shape: const RoundedRectangleBorder(),
                backgroundColor: colors.actionPrimary,
                foregroundColor: colors.onPrimary,
                disabledBackgroundColor: Color.lerp(
                  colors.canvas,
                  colors.actionPrimary,
                  0.35,
                ),
                disabledForegroundColor: colors.onPrimary,
              ),
              child: Text(importLabel),
            ),
          ],
        ),
      ),
    );
  }
}
