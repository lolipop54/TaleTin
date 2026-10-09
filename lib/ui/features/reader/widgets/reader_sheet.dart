import 'package:taletin/ui/core/widgets/gt_button.dart';
import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/theme/gt_tokens.dart';
import '../../../core/widgets/gt_icon.dart';

/// 阅读器底部「纸张面板」统一外壳（设计文档 9.1）：
/// 直角纸张背景 + 标题区 + 关闭按钮。
/// 面板不使用蓝色折角与悬浮卡片。
class ReaderSheet extends StatelessWidget {
  const ReaderSheet({
    super.key,
    required this.title,
    required this.onClose,
    required this.child,
    this.subtitle,
    this.maxHeightFactor = 0.82,
    this.footer,
    this.collapsible = true,
  });

  final String title;
  final String? subtitle;
  final VoidCallback onClose;
  final Widget child;
  final double maxHeightFactor;

  /// 主工具面板向下收起；笔记编辑器仍用关闭图标。
  final bool collapsible;

  /// 面板底部固定区（如「新建笔记」）
  final Widget? footer;

  /// 由阅读区域提供颜色，独立页面沿用所在区域的应用主题。
  static Color backgroundOf(BuildContext context) => context.gtColors.surface;

  static Color scrimOf(BuildContext context) => context.gtColors.scrim;

  @override
  Widget build(BuildContext context) {
    final colors = context.gtColors;
    final media = MediaQuery.of(context);
    // 上限按「键盘弹起后还剩多少高度」算：笔记编辑器是独立弹层，不在阅读页
    // 的 Scaffold 里，键盘高度不会被扣掉，直接用屏幕高度会让面板顶到状态栏上
    final available = media.size.height - media.viewInsets.bottom;
    return Container(
      constraints: BoxConstraints(maxHeight: available * maxHeightFactor),
      color: backgroundOf(context),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 标题行
          Padding(
            padding: const EdgeInsets.fromLTRB(
              GtSpacing.s5,
              GtSpacing.s3,
              GtSpacing.s5,
              GtSpacing.s1,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: GtText.pageTitle(colors.textPrimary)
                            .copyWith(fontSize: 18),
                      ),
                      if (subtitle != null)
                        Text(
                          subtitle!,
                          style: GtText.caption(colors.textMuted)
                              .copyWith(fontSize: 12),
                        ),
                    ],
                  ),
                ),
                SizedBox(
                  width: 32,
                  height: 32,
                  child: GtButton.icon(
                    style: GtButton.compactIconStyle,
                    tooltip: collapsible ? '收起' : '关闭',
                    onPressed: onClose,
                    icon: GtIcon(
                      collapsible ? GtIcons.chevronDown : GtIcons.close,
                      size: 23,
                      color: colors.textPrimary,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Flexible(child: child),
          ?footer,
          SizedBox(height: media.padding.bottom + GtSpacing.s2),
        ],
      ),
    );
  }
}
