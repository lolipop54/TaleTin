import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/di/app_providers.dart';
import '../../../../app/di/statistics_providers.dart';
import '../../../../app/di/statistics_settings_providers.dart';
import '../../../../domain/models/reading_statistics.dart';
import '../../../../domain/services/reading_statistics_summary.dart';

class StatisticsPageData {
  const StatisticsPageData(
    this.statistics,
    this.bookTitles, {
    this.includeAudio = true,
    this.bookCovers = const {},
  });
  final Map<String, String> bookCovers;
  final bool includeAudio;
  ReadingStatisticsSummary overviewSummary(DateTime now) => includeAudio
      ? summary(now)
      : ReadingStatisticsSummary(
          ReadingStatistics(
            days: statistics.days.map(
              (d) => DailyReadingStats(
                date: d.date,
                visualMs: d.visualMs,
                audioMs: d.audioMs,
                totalMs: d.visualMs,
              ),
            ),
            sessions: statistics.sessions,
            segments: statistics.segments,
          ),
          now,
        );
  final ReadingStatistics statistics;
  final Map<String, String> bookTitles;
  ReadingStatisticsSummary summary(DateTime now) =>
      ReadingStatisticsSummary(statistics, now);
  String title(String bookId) => bookTitles[bookId] ?? '已移除书籍';
}

/// 时长和书名全部准备好再发布，刷新期间页面沿用上一次完整结果。
final statisticsPageProvider = StreamProvider<StatisticsPageData>((ref) async* {
  final books = ref.watch(bookRepositoryProvider);
  final repository = ref.watch(readingStatisticsRepositoryProvider);
  final settings = await ref.watch(statisticsSettingsProvider.future);
  yield* repository.watch().asyncMap((data) async {
    final ids = data.sessions.map((s) => s.bookId).toSet();
    final covers = <String, String>{};
    final root = ref.read(libraryRootPathProvider);
    final titles = await Future.wait(
      ids.map((id) async {
        final book = await books.findById(id);
        if (book?.coverPath case final path?) covers[id] = '$root/$id/$path';
        return MapEntry(id, book?.title ?? '已移除书籍');
      }),
    );
    return StatisticsPageData(
      data,
      Map.unmodifiable(Map.fromEntries(titles)),
      bookCovers: Map.unmodifiable(covers),
      includeAudio: settings.includeAudio,
    );
  });
});

/// 没有新增片段时，跨日后今日/本周仍能按本地日期刷新。
final statisticsDateProvider = StreamProvider<DateTime>((ref) async* {
  yield DateTime.now();
  yield* Stream.periodic(const Duration(minutes: 1), (_) => DateTime.now());
});

String readingDuration(int ms) {
  if (ms <= 0) return '0分钟';
  if (ms < 1000) return '不足1秒';
  if (ms < 60000) return '${ms ~/ 1000}秒';
  final minutes = ms ~/ 60000;
  return minutes < 60 ? '$minutes分钟' : '${minutes ~/ 60}小时${minutes % 60}分';
}

String latestReadingLabel(LatestReading? latest) {
  if (latest == null) return '暂无记录';
  final time = latest.localEnd;
  final hh = time.hour.toString().padLeft(2, '0');
  final mm = time.minute.toString().padLeft(2, '0');
  return '${latest.nightDate}\n${latest.nextDay ? '次日 ' : ''}$hh:$mm';
}
