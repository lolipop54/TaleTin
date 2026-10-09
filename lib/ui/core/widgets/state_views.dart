import 'package:taletin/ui/core/widgets/gt_button.dart';
import 'package:flutter/material.dart';


import '../theme/app_theme.dart';
import '../theme/gt_tokens.dart';
import 'gt_icon.dart';

/// 统一页面状态：加载中 / 空数据 / 失败重试。
/// 所有页面在数据就绪后才展示正式内容，避免“默认数据先闪一下”。

/// 数据准备期间的稳定加载态。
class GtLoadingView extends StatelessWidget {
  const GtLoadingView({super.key, this.label = '正在准备…'});

  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = context.gtColors;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 40, height: 40,
            child: SizedBox.shrink(),
          ),
          const SizedBox(height: GtSpacing.s3),
          Text(label, style: GtText.caption(colors.textMuted)),
        ],
      ),
    );
  }
}

/// 确认没有数据之后的空态。
class GtEmptyView extends StatelessWidget {
  const GtEmptyView({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.actionLabel,
    this.onAction,
  });

  final String icon;
  final String title;
  final String? message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final colors = context.gtColors;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(GtSpacing.s8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            GtIcon(icon, size: 44, color: colors.textMuted.withValues(alpha: 0.6)),
            const SizedBox(height: GtSpacing.s3),
            Text(title, style: GtText.sectionTitle(colors.textPrimary)),
            if (message != null) ...[
              const SizedBox(height: GtSpacing.s2),
              Text(message!,
                  textAlign: TextAlign.center,
                  style: GtText.caption(colors.textMuted)),
            ],
            if (actionLabel != null) ...[
              const SizedBox(height: GtSpacing.s4),
              GtButton.filled(
                onPressed: onAction,
                style: FilledButton.styleFrom(
                  backgroundColor: colors.actionPrimary,
                  foregroundColor: colors.onPrimary,
                ),
                child: Text(actionLabel!),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 读取失败：错误说明 + 重试入口。
class GtErrorView extends StatelessWidget {
  const GtErrorView({
    super.key,
    required this.title,
    this.message,
    required this.onRetry,
  });

  final String title;
  final String? message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return GtEmptyView(
      icon: GtIcons.alertCircle,
      title: title,
      message: message,
      actionLabel: '重试',
      onAction: onRetry,
    );
  }
}
