import 'package:taletin/ui/core/widgets/gt_button.dart';
import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../core/theme/gt_tokens.dart';
import '../../../../core/widgets/gt_icon.dart';
import 'annotation_text.dart';

/// 笔记与书签共用的真实列表条目。
class ReaderAnnotationItem extends StatelessWidget {
  const ReaderAnnotationItem({
    super.key,
    required this.chipLabel,
    required this.chipColor,
    required this.date,
    required this.quote,
    required this.quoteHighlight,
    required this.location,
    this.onJump,
    this.onDelete,
    this.onEdit,
    this.body = '',
    this.quoteMaxLines = 5,
  });

  final String chipLabel;
  final Color chipColor;
  final String date;
  final String quote;
  final Color? quoteHighlight;
  final String location;
  final VoidCallback? onJump;
  final VoidCallback? onDelete;
  final VoidCallback? onEdit;
  final String body;
  final int quoteMaxLines;

  @override
  Widget build(BuildContext context) {
    final colors = context.gtColors;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: GtSpacing.s4),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colors.borderSubtle)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: double.infinity,
            child: Wrap(
              spacing: GtSpacing.s3,
              runSpacing: GtSpacing.s2,
              alignment: WrapAlignment.spaceBetween,
              children: [
                Text(
                  location,
                  style: GtText.caption(colors.textSecondary)
                      .copyWith(fontSize: 12),
                ),
                Text(
                  date,
                  style: GtText.caption(colors.textMuted)
                      .copyWith(fontSize: 12),
                ),
              ],
            ),
          ),
          const SizedBox(height: GtSpacing.s2),
          AnnotationText(
            text: quote,
            label: '原文',
            maxLines: quoteMaxLines,
            expandable: false,
            // 夜间降低高亮底色亮度，让浅色摘录文字仍保持清晰。
            highlight: Theme.of(context).brightness == Brightness.dark
                ? quoteHighlight?.withValues(alpha: .24)
                : quoteHighlight,
            style: GtText.body(colors.textPrimary)
                .copyWith(fontSize: 14, fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: GtSpacing.s2),
          if (body.isNotEmpty) ...[
            AnnotationText(
              text: body,
              label: '想法',
              style: GtText.body(colors.textSecondary),
            ),
            const SizedBox(height: GtSpacing.s1),
          ],
          // 三颗按钮统一用小号尺寸，触摸范围贴合文字，避免互相误触。
          Row(
            children: [
              const Spacer(),
              if (onEdit != null)
                GtButton(
                  onPressed: onEdit,
                  style: GtButton.compactStyle,
                  child: const Text('编辑', style: TextStyle(fontSize: 12)),
                ),
              if (onDelete != null)
                GtButton(
                  onPressed: onDelete,
                  style: GtButton.compactStyle,
                  child: const Text('删除', style: TextStyle(fontSize: 12)),
                ),
              if (onJump != null)
                GtButton(
                  onPressed: onJump,
                  style: GtButton.compactStyle.copyWith(
                    padding: WidgetStatePropertyAll(
                      EdgeInsets.only(left: 8, top: 4, bottom: 4),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '跳转',
                        style: GtText.caption(
                          colors.actionPrimary,
                        ).copyWith(fontSize: 12, fontWeight: FontWeight.w500),
                      ),
                      GtIcon(
                        GtIcons.chevronRight,
                        size: 14,
                        color: colors.actionPrimary,
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
