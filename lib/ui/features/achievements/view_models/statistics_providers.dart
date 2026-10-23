import '../../../core/widgets/book_cover_resources.dart';
import '../../../../domain/models/book_cover_choice.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/di/app_providers.dart';
import '../../../../app/di/statistics_providers.dart';
import '../../../../app/di/statistics_settings_providers.dart';
import '../../../../domain/models/reading_statistics.dart';
import '../../../../domain/services/reading_statistics_summary.dart';
import '../../../../domain/services/reading_segment_slicer.dart';
import '../../../../data/services/statistics_compute.dart';

class StatisticsPageData {
  StatisticsPageData(
    this.statistics,
    this.bookTitles, {
    this.includeAudio = true,
    this.bookCovers = const {},
    this.bookCoverPresets = const {},
    this.bookAuthors = const {},
    this.customImageBookIds = const {},
    this.loadDay,
    PreparedStatistics? prepared,
  }) : _all = prepared?.$1,
       _overview = prepared?.$2,
       _prepared = prepared != null;
  final bool _prepared;
  ReadingStatisticsSummary? _all, _overview;
  bool _sameDay(ReadingStatisticsSummary? summary, DateTime now) =>
      summary?.today == DateTime.utc(now.year, now.month, now.day);
  final Map<String, String> bookCovers;
  final Map<String, BookCoverPreset> bookCoverPresets;
  final Map<String, String> bookAuthors;
  final Set<String> customImageBookIds;
  final bool includeAudio;
  final Future<StatisticsPageData> Function(String date)? loadDay;
  ReadingStatisticsSummary overviewSummary(DateTime now) {
    if (includeAudio) return summary(now);
    if (_prepared || _sameDay(_overview, now)) return _overview!;
    return _overview = ReadingStatisticsSummary(
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
  }

  final ReadingStatistics statistics;
  final Map<String, String> bookTitles;
  ReadingStatisticsSummary summary(DateTime now) =>
      _prepared || _sameDay(_all, now)
      ? _all!
      : _all = ReadingStatisticsSummary(statistics, now);
  String title(String bookId) => bookTitles[bookId] ?? '已移除书籍';
}

/// 时长和书名全部准备好再发布，刷新期间页面沿用上一次完整结果。
final statisticsPageProvider = StreamProvider<StatisticsPageData>((ref) async* {
  // 跨日也重新准备完整统计；新快照就绪前页面继续使用上一份，避免午夜首次重建做重计算。
  ref.watch(
    statisticsDateProvider.select((value) {
      final now = value.value;
      return now == null ? null : DateTime(now.year, now.month, now.day);
    }),
  );
  final books = ref.watch(bookRepositoryProvider);
  final repository = ref.watch(readingStatisticsRepositoryProvider);
  final settings = await ref.watch(statisticsSettingsProvider.future);
  Future<StatisticsPageData> prepare(
    ReadingStatistics data, {
    bool overview = false,
  }) async {
    final prepared = await prepareStatistics(data, settings.includeAudio);
    final ids = data.sessions.map((s) => s.bookId).toSet();
    final covers = <String, String>{};
    final presets = <String, BookCoverPreset>{};
    final authors = <String, String>{};
    final customImages = <String>{};
    final coverFile = ref.read(bookCoverFileProvider);
    final titles = await Future.wait(
      ids.map((id) async {
        final book = await books.findById(id);
        if (book != null) {
          authors[id] = book.author;
          if (book.coverChoice?.imagePath != null) customImages.add(id);
          if (coverFile(book) case final path?) covers[id] = path;
          if (book.coverChoice?.preset case final preset?) presets[id] = preset;
        }
        return MapEntry(id, book?.title ?? '已移除书籍');
      }),
    );
    if (presets.isNotEmpty) await BookCoverResources.prepare();
    return StatisticsPageData(
      data,
      Map.unmodifiable(Map.fromEntries(titles)),
      prepared: prepared,
      bookCovers: Map.unmodifiable(covers),
      bookCoverPresets: Map.unmodifiable(presets),
      bookAuthors: Map.unmodifiable(authors),
      customImageBookIds: Set.unmodifiable(customImages),
      includeAudio: settings.includeAudio,
      loadDay: !overview
          ? null
          : (date) async {
              final next = readingDate(
                DateTime.parse(date).add(const Duration(days: 1)),
              );
              return prepare(await repository.loadRange(date, next));
            },
    );
  }

  yield* repository.watchOverview().asyncMap(
    (data) => prepare(data, overview: true),
  );
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
