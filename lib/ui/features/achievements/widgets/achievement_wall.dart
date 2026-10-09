import 'package:taletin/ui/core/widgets/gt_button.dart';
import 'package:flutter/material.dart';

import '../../../../domain/rules/achievement_rules.dart';
import '../../../../domain/services/reading_statistics_summary.dart';
import 'achievement_details_dialog.dart';
import '../../../core/theme/gt_tokens.dart';
import '../../../core/widgets/state_views.dart';

ImageProvider achievementImage(AchievementRule rule, {int width = 256}) =>
    ResizeImage(AssetImage(rule.asset), width: width);

/// 与徽章显示共用相同缓存键，主导航可在用户打开成就页前准备素材。
Future<void> prepareAchievementArt(BuildContext context) => Future.wait(
  achievementRules
      .map((r) => r.art)
      .toSet()
      .map(
        (art) => precacheImage(
          ResizeImage(AssetImage('assets/achievements/$art.png'), width: 256),
          context,
        ),
      ),
).then((_) {});

/// 首屏先解码全部专属勋章，避免数据已显示、徽章再逐个跳出来。
class AchievementArtReady extends StatefulWidget {
  const AchievementArtReady({super.key, required this.child});
  final Widget child;
  @override
  State<AchievementArtReady> createState() => _AchievementArtReadyState();
}

class _AchievementArtReadyState extends State<AchievementArtReady> {
  Future<void>? prepared;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    prepared ??= prepareAchievementArt(context);
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<void>(
    future: prepared,
    builder: (context, state) => state.connectionState == ConnectionState.done
        ? widget.child
        : const Scaffold(body: GtLoadingView(label: '正在准备成就…')),
  );
}

String achievementProgress(AchievementRule rule, int value) {
  if (rule.metric == AchievementMetric.time) {
    return '${((value / 360000).floor() / 10).toStringAsFixed(1)} / ${rule.target ~/ 3600000} 小时';
  }
  final unit = switch (rule.metric) {
    AchievementMetric.days || AchievementMetric.streak => '天',
    _ => '本',
  };
  return '$value / ${rule.target} $unit';
}

class AchievementMedal extends StatelessWidget {
  const AchievementMedal({
    super.key,
    required this.rule,
    required this.unlocked,
    this.size = 80,
  });
  final AchievementRule rule;
  final bool unlocked;
  final double size;
  @override
  Widget build(BuildContext context) {
    final art = Image(
      image: achievementImage(rule),
      width: size,
      height: size,
      excludeFromSemantics: true,
    );
    return unlocked
        ? art
        : Opacity(
            opacity: .55,
            child: ColorFiltered(
              colorFilter: const ColorFilter.matrix([
                .2126,
                .7152,
                .0722,
                0,
                0,
                .2126,
                .7152,
                .0722,
                0,
                0,
                .2126,
                .7152,
                .0722,
                0,
                0,
                0,
                0,
                0,
                1,
                0,
              ]),
              child: art,
            ),
          );
  }
}

class AchievementWall extends StatelessWidget {
  const AchievementWall({super.key, required this.data});
  final AchievementEvaluation data;
  static const groups = {
    AchievementMetric.days: '阅读累计天数',
    AchievementMetric.streak: '连续阅读天数',
    AchievementMetric.time: '阅读累计时长',
    AchievementMetric.completed: '阅读书籍',
  };
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        '阅读勋章 · ${achievementRules.where((r) => data.unlock(r.id) != null).length}/${achievementRules.length}',
        style: TextStyle(
          fontSize: 21,
          fontWeight: FontWeight.w700,
          color: context.gtColors.textPrimary,
        ),
      ),
      for (final group in groups.entries) ...[
        const SizedBox(height: 24),
        Text(
          group.value,
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: context.gtColors.textPrimary,
          ),
        ),
        const SizedBox(height: 12),
        LayoutBuilder(
          builder: (context, box) {
            final columns =
                box.maxWidth / MediaQuery.textScalerOf(context).scale(1) >= 480
                ? 4
                : 2;
            final width = (box.maxWidth - (columns - 1) * 16) / columns;
            return Wrap(
              spacing: 16,
              runSpacing: 18,
              children: [
                for (final rule in achievementRules.where(
                  (r) => r.metric == group.key,
                ))
                  SizedBox(
                    width: width,
                    child: GtButton.raw(
                      key: ValueKey('achievement-${rule.id}'),
                      borderRadius: BorderRadius.circular(16),
                      onPressed: () =>
                          showAchievementDetails(context, rule, data),
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: Column(
                          children: [
                            AchievementMedal(
                              rule: rule,
                              unlocked: data.unlock(rule.id) != null,
                              size: 104,
                            ),
                            const SizedBox(height: 8),
                            Text(
                              rule.title,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: context.gtColors.textPrimary,
                                fontWeight: FontWeight.w600,
                                fontSize: 13,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              data.unlock(rule.id) != null ? '已解锁' : '未解锁',
                              style: TextStyle(
                                color: context.gtColors.textSecondary,
                                fontSize: 11,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 12.0),
                              child: LinearProgressIndicator(
                                backgroundColor: context.gtColors.borderSubtle,
                                color: context.gtColors.actionPrimary,
                                stopIndicatorRadius: 0,
                                minHeight: 3,
                                value:
                                    (data.facts.value(rule.metric) / rule.target)
                                        .clamp(0.0, 1.0),
                                semanticsLabel: rule.condition,
                              ),
                            ),
                            const SizedBox(height: 5),
                            Text(
                              achievementProgress(
                                rule,
                                data.facts.value(rule.metric),
                              ),
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 11,
                                color: context.gtColors.textSecondary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    ],
  );
}

Future<void> showAchievementDetails(
  BuildContext context,
  AchievementRule rule,
  AchievementEvaluation data,
) async {
  final unlocked = data.unlock(rule.id);
  final image = achievementImage(rule, width: 640);
  // 放大图先解码，再打开弹窗；墙上的小图仍沿用原缓存。
  await precacheImage(image, context);
  if (!context.mounted) return;
  // 连续天数要从当前连续纪录继续，不能把已中断的历史最佳当作剩余进度。
  final value = rule.metric == AchievementMetric.streak
      ? ReadingStatisticsSummary(data.facts.statistics, DateTime.now()).streak
      : data.facts.value(rule.metric);
  await showDialog<void>(
    context: context,
    useRootNavigator: true,
    animationStyle: MediaQuery.disableAnimationsOf(context)
        ? AnimationStyle.noAnimation
        : null,
    barrierColor: context.gtColors.scrim.withValues(alpha: .8),
    builder: (_) => AchievementDetailsDialog(
      rule: rule,
      image: image,
      unlock: unlocked,
      remaining: achievementRemaining(rule, value, unlocked: unlocked != null),
    ),
  );
}
