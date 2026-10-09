import 'package:taletin/ui/core/widgets/gt_button.dart';
import 'package:flutter/material.dart';

import '../../../../app/router/main_pages_ready.dart';
import '../../../../app/di/completion_providers.dart';
import '../widgets/achievement_wall.dart';
import '../widgets/achievement_reward_host.dart';
import '../../../../app/di/achievement_providers.dart';
import '../../../../domain/rules/achievement_rules.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../view_models/statistics_providers.dart';
import '../../../core/widgets/state_views.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/gt_tokens.dart';
import '../widgets/calendar_card.dart';
import '../widgets/reading_day_sheet.dart';

/// 成就与阅读统计页（参考图 04）。
/// 概览四项 → 阅读月历 → 阅读记录 → 四组阅读勋章。
class AchievementsView extends ConsumerWidget {
  const AchievementsView({super.key, this.artPrepared = false});

  /// 主导航已经等徽章就绪；独立页面入口仍自行准备，避免首帧闪加载态。
  final bool artPrepared;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    MainPagesReady.dependOn(context);
    final state = ref.watch(statisticsPageProvider);
    final date = ref.watch(statisticsDateProvider).value ?? DateTime.now();
    final completions = ref.watch(bookCompletionsProvider);
    final achievements = ref.watch(achievementPageProvider);
    final data = state.value;
    if (data == null ||
        completions.value == null ||
        achievements.value == null) {
      return Scaffold(
        body: (state.hasError || completions.hasError || achievements.hasError)
            ? GtErrorView(
                title: '阅读统计暂时无法读取',
                onRetry: () {
                  ref.invalidate(statisticsPageProvider);
                  ref.invalidate(bookCompletionsProvider);
                  ref.invalidate(achievementPageProvider);
                },
              )
            : const GtLoadingView(label: '正在读取阅读记录…'),
      );
    }
    final page = AchievementRewardHost(
      child: _AchievementsPage(
        data: data,
        now: date,
        achievements: achievements.value!,
        error: state.hasError || completions.hasError || achievements.hasError,
        retry: () {
          ref.invalidate(statisticsPageProvider);
          ref.invalidate(bookCompletionsProvider);
          ref.read(achievementServiceProvider).refresh();
        },
        completedCount: completions.value!
            .where((r) => r.active)
            .map((r) => r.bookId)
            .toSet()
            .length,
      ),
    );
    return artPrepared ? page : AchievementArtReady(child: page);
  }
}

class _AchievementsPage extends StatelessWidget {
  const _AchievementsPage({
    required this.data,
    required this.now,
    required this.error,
    required this.retry,
    required this.completedCount,
    required this.achievements,
  });
  final AchievementEvaluation achievements;
  final int completedCount;
  final StatisticsPageData data;
  final DateTime now;
  final bool error;
  final VoidCallback retry;

  @override
  Widget build(BuildContext context) {
    final colors = context.gtColors;
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(
            GtSpacing.s5,
            GtSpacing.s5,
            GtSpacing.s5,
            GtSpacing.s6,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildHeader(context, colors),
              if (error)
                GtButton(
                  onPressed: retry,
                  child: const Text('更新失败，保留上次记录。点击重试'),
                ),
              const SizedBox(height: GtSpacing.s4),
              _buildOverview(context, colors),
              const SizedBox(height: GtSpacing.s4),
              // 概览与月历之间的分隔线（参考图 04）
              Container(height: 1, color: colors.borderSubtle),
              const SizedBox(height: GtSpacing.s4),
              CalendarCard(
                days: data.statistics.days,
                today: now,
                onDate: (date) => showReadingDay(context, data, now, date),
              ),
              const SizedBox(height: GtSpacing.s5),
              Container(height: 1, color: colors.borderSubtle),
              const SizedBox(height: GtSpacing.s4),
              _buildRecords(context, colors),
              const SizedBox(height: GtSpacing.s5),
              AchievementWall(data: achievements),
            ],
          ),
        ),
      ),
    );
  }

  /// 页头：蓝色竖条 + 大标题 + 副标题 + 右侧竖排落款。
  Widget _buildHeader(BuildContext context, GtColors colors) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 5,
          height: 44,
          margin: const EdgeInsets.only(right: GtSpacing.s3, top: 6),
          color: colors.actionPrimary,
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '成就',
                style: GtText.pageTitle(colors.textPrimary)
                    .copyWith(fontSize: 25),
              ),
              const SizedBox(height: GtSpacing.s1),
              Text(
                '以阅读，见更大的自己',
                style: GtText.body(colors.textSecondary)
                    .copyWith(fontSize: 14, letterSpacing: 1),
              ),
            ],
          ),
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            // 右侧落款是横排两行、右对齐（参考图 04）
            Text(
              '书页之间',
              style: GtText.caption(colors.textSecondary)
                  .copyWith(fontSize: 11, height: 1.7),
            ),
            Text(
              '自有远方',
              style: GtText.caption(colors.textSecondary)
                  .copyWith(fontSize: 11, height: 1.7),
            ),
            const SizedBox(height: GtSpacing.s2),
            Container(width: 18, height: 1, color: colors.borderControl),
          ],
        ),
      ],
    );
  }

  /// 概览：今日 / 本周 / 累计 / 连续。
  Widget _buildOverview(BuildContext context, GtColors colors) {
    final s = data.overviewSummary(now);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _metric(context, '今日', readingDuration(s.todayMs)),
        _verticalDivider(context, colors),
        _metric(context, '本周', readingDuration(s.weekMs)),
        _verticalDivider(context, colors),
        _metric(context, '累计', readingDuration(s.totalMs)),
        _verticalDivider(context, colors),
        _metric(context, '连续', '${s.streak}天'),
      ],
    );
  }

  Widget _metric(BuildContext context, String label, String value) {
    final colors = context.gtColors;
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: GtText.caption(colors.textSecondary).copyWith(fontSize: 13),
          ),
          const SizedBox(height: GtSpacing.s1),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              value,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                height: 1.15,
                color: colors.actionPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _verticalDivider(BuildContext context, GtColors colors) => Container(
    width: 1,
    height: 40,
    margin: const EdgeInsets.symmetric(horizontal: GtSpacing.s2),
    color: colors.borderSubtle,
  );

  /// 阅读记录概览，已移除独立详情与跨书笔记入口。
  Widget _buildRecords(BuildContext context, GtColors colors) {
    final r = data.summary(now);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '阅读记录',
          style: GtText.sectionTitle(colors.textPrimary)
              .copyWith(fontSize: 21, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: GtSpacing.s4),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _record(context, '已读书籍', '$completedCount本'),
            _verticalDivider(context, colors),
            _record(
              context,
              '单次最长',
              readingDuration(r.longestSession?.activeMs ?? 0),
            ),
            _verticalDivider(context, colors),
            _record(
              context,
              '单日最多',
              readingDuration(r.longestDay?.totalMs ?? 0),
            ),
            _verticalDivider(context, colors),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '最晚阅读',
                    style: GtText.caption(colors.textSecondary)
                        .copyWith(fontSize: 13),
                  ),
                  const SizedBox(height: GtSpacing.s1),
                  // 日期与时间两行，字号放大时整体缩放，避免被裁掉
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(
                      latestReadingLabel(r.latest),
                      maxLines: 2,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        height: 1.32,
                        color: colors.actionPrimary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _record(BuildContext context, String label, String value) {
    final colors = context.gtColors;
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: GtText.caption(colors.textSecondary).copyWith(fontSize: 13),
          ),
          const SizedBox(height: GtSpacing.s1),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              value,
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w600,
                height: 1.3,
                color: colors.actionPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
