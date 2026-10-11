import '../models/reading_statistics.dart';
import '../models/book_completion.dart';

enum AchievementMetric { days, streak, time, completed }

const achievementRuleVersion = 2;

class AchievementRule {
  const AchievementRule(
    this.id,
    this.title,
    this.condition,
    this.metric,
    this.target,
    this.art,
  );
  final String id, title, condition, art;
  final AchievementMetric metric;
  final int target;
  int get version => achievementRuleVersion;
  String get asset => 'assets/achievements/$art.webp';
}

/// 新版规则重新计算解锁记录；已解锁的新勋章不随普通撤销读完记录回收。
const achievementRules = [
  AchievementRule(
    'days.100',
    '累计阅读100天',
    '累计 100 个自然日，每天有效阅读与听书合计至少 1 分钟。',
    AchievementMetric.days,
    100,
    'days_100',
  ),
  AchievementRule(
    'days.200',
    '累计阅读200天',
    '累计 200 个自然日，每天有效阅读与听书合计至少 1 分钟。',
    AchievementMetric.days,
    200,
    'days_200',
  ),
  AchievementRule(
    'days.365',
    '累计阅读365天',
    '累计 365 个自然日，每天有效阅读与听书合计至少 1 分钟。',
    AchievementMetric.days,
    365,
    'days_365',
  ),
  AchievementRule(
    'days.1000',
    '累计阅读1000天',
    '累计 1000 个自然日，每天有效阅读与听书合计至少 1 分钟。',
    AchievementMetric.days,
    1000,
    'days_1000',
  ),
  AchievementRule(
    'streak.30',
    '连续阅读30天',
    '连续 30 个自然日，每天有效阅读与听书合计至少 1 分钟。',
    AchievementMetric.streak,
    30,
    'streak_30',
  ),
  AchievementRule(
    'streak.90',
    '连续阅读90天',
    '连续 90 个自然日，每天有效阅读与听书合计至少 1 分钟。',
    AchievementMetric.streak,
    90,
    'streak_90',
  ),
  AchievementRule(
    'streak.180',
    '连续阅读180天',
    '连续 180 个自然日，每天有效阅读与听书合计至少 1 分钟。',
    AchievementMetric.streak,
    180,
    'streak_180',
  ),
  AchievementRule(
    'streak.365',
    '连续阅读365天',
    '连续 365 个自然日，每天有效阅读与听书合计至少 1 分钟。',
    AchievementMetric.streak,
    365,
    'streak_365',
  ),
  AchievementRule(
    'time.100',
    '累计阅读100小时',
    '累计有效阅读与听书达到 100 小时，重叠时间只计一次。',
    AchievementMetric.time,
    360000000,
    'hours_100',
  ),
  AchievementRule(
    'time.500',
    '累计阅读500小时',
    '累计有效阅读与听书达到 500 小时，重叠时间只计一次。',
    AchievementMetric.time,
    1800000000,
    'hours_500',
  ),
  AchievementRule(
    'time.1000',
    '累计阅读1000小时',
    '累计有效阅读与听书达到 1000 小时，重叠时间只计一次。',
    AchievementMetric.time,
    3600000000,
    'hours_1000',
  ),
  AchievementRule(
    'time.3000',
    '累计阅读3000小时',
    '累计有效阅读与听书达到 3000 小时，重叠时间只计一次。',
    AchievementMetric.time,
    10800000000,
    'hours_3000',
  ),
  AchievementRule(
    'completion.10',
    '读完10本书',
    '亲自确认读完 10 本不同的书。',
    AchievementMetric.completed,
    10,
    'books_10',
  ),
  AchievementRule(
    'completion.20',
    '读完20本书',
    '亲自确认读完 20 本不同的书。',
    AchievementMetric.completed,
    20,
    'books_20',
  ),
  AchievementRule(
    'completion.50',
    '读完50本书',
    '亲自确认读完 50 本不同的书。',
    AchievementMetric.completed,
    50,
    'books_50',
  ),
  AchievementRule(
    'completion.100',
    '读完100本书',
    '亲自确认读完 100 本不同的书。',
    AchievementMetric.completed,
    100,
    'books_100',
  ),
];

class AchievementFacts {
  AchievementFacts({
    required this.statistics,
    required Iterable<BookCompletion> completions,
  }) : completedBooks = completions
           .where((r) => r.active)
           .map((r) => r.bookId)
           .toSet();
  final ReadingStatistics statistics;
  final Set<String> completedBooks;

  /// 使用历史最佳连续天数，离线重算也能找回曾经达成的里程碑。
  int get bestStreak {
    // 日期仅比较日历相邻关系，使用 UTC 避免夏令时的 23 小时跨日被算成 0 天。
    final dates =
        statistics.days
            .where((d) => d.totalMs >= 60000)
            .map((d) => DateTime.parse('${d.date}T00:00:00Z'))
            .toList()
          ..sort();
    var best = 0, count = 0;
    DateTime? previous;
    for (final date in dates) {
      count = previous != null && date.difference(previous).inDays == 1
          ? count + 1
          : 1;
      if (count > best) best = count;
      previous = date;
    }
    return best;
  }

  int value(AchievementMetric metric) => switch (metric) {
    AchievementMetric.days =>
      statistics.days.where((d) => d.totalMs >= 60000).length,
    AchievementMetric.time => statistics.days.fold(
      0,
      (sum, d) => sum + d.totalMs,
    ),
    AchievementMetric.completed => completedBooks.length,
    AchievementMetric.streak => bestStreak,
  };
}

class AchievementUnlock {
  const AchievementUnlock({
    required this.id,
    required this.ruleVersion,
    required this.unlockedAt,
    required this.progressSnapshot,
    required this.presented,
  });
  final String id;
  final int ruleVersion, progressSnapshot;
  final DateTime unlockedAt;
  final bool presented;
}

class AchievementEvaluation {
  const AchievementEvaluation(this.facts, this.unlocks);
  final AchievementFacts facts;
  final List<AchievementUnlock> unlocks;
  AchievementUnlock? unlock(String id) {
    for (final item in unlocks) {
      if (item.id == id) return item;
    }
    return null;
  }
}
