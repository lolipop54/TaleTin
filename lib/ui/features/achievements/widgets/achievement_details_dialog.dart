import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../../domain/rules/achievement_rules.dart';
import '../../../core/theme/gt_tokens.dart';
import '../../../core/widgets/gt_button.dart';

/// 时长向上取整，不能把尚差几分钟的勋章显示成已达成。
String achievementRemaining(
  AchievementRule rule,
  int value, {
  bool unlocked = false,
}) {
  final remaining = (rule.target - value).clamp(0, rule.target);
  if (unlocked || remaining == 0) return '已达成';
  return switch (rule.metric) {
    AchievementMetric.time => '再阅读${(remaining / 3600000).ceil()}小时可获得',
    AchievementMetric.completed => '再阅读$remaining本书可获得',
    AchievementMetric.streak => '再连续阅读$remaining天可获得',
    AchievementMetric.days => '再阅读$remaining天可获得',
  };
}

String achievementUnlockLabel(AchievementUnlock? unlock) {
  if (unlock == null) return '尚未解锁';
  final date = unlock.unlockedAt.toLocal();
  return '${date.year}/${date.month.toString().padLeft(2, '0')}/${date.day.toString().padLeft(2, '0')} 已解锁';
}

/// 中央展示卡片与独立圆形关闭按钮；大字号只滚动卡片，关闭仍可见。
class AchievementDetailsDialog extends StatelessWidget {
  const AchievementDetailsDialog({
    super.key,
    required this.rule,
    required this.image,
    required this.remaining,
    required this.unlock,
  });
  final AchievementRule rule;
  final ImageProvider image;
  final String remaining;
  final AchievementUnlock? unlock;

  @override
  Widget build(BuildContext context) {
    final c = context.gtColors;
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              fit: FlexFit.loose,
              child: Container(
                key: const ValueKey('achievement-detail-card'),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(GtRadius.dialog),
                  color: c.surface,
                  gradient: RadialGradient(
                    radius: 1.1,
                    center: const Alignment(0, -.25),
                    colors: [
                      Color.alphaBlend(
                        c.actionPrimary.withValues(alpha: .09),
                        c.surface,
                      ),
                      c.surface,
                    ],
                  ),
                  border: Border.all(color: c.borderSubtle),
                ),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      LayoutBuilder(
                        builder: (context, box) {
                          final size = math.min(220.0, box.maxWidth);
                          return SizedBox(
                            key: const ValueKey('achievement-medal-display'),
                            width: box.maxWidth,
                            height: size,
                            child: Center(
                              child: Image(
                                image: image,
                                width: size,
                                height: size,
                                semanticLabel: rule.title,
                              ),
                            ),
                          );
                        },
                      ),
                      const SizedBox(height: 24),
                      Text(
                        rule.condition,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 19,
                          height: 1.5,
                          fontWeight: FontWeight.w700,
                          color: c.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 18),
                      Text(
                        remaining,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 15,
                          height: 1.5,
                          color: c.actionPrimary,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        achievementUnlockLabel(unlock),
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 14,
                          height: 1.5,
                          color: c.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 20),
            GtButton.raw(
              key: const ValueKey('achievement-detail-close'),
              tooltip: '关闭勋章详情',
              borderRadius: BorderRadius.circular(32),
              onPressed: () => Navigator.pop(context),
              child: Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: c.surface,
                  border: Border.all(color: c.borderSubtle),
                ),
                child: Icon(
                  Icons.close_rounded,
                  size: 30,
                  color: c.textPrimary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
