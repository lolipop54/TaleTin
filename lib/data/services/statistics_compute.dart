import '../../core/concurrency/background_compute.dart';
import '../../domain/models/book_completion.dart';
import '../../domain/models/reading_statistics.dart';
import '../../domain/rules/achievement_rules.dart';
import '../../domain/services/reading_statistics_aggregation.dart';
import '../../domain/services/reading_statistics_summary.dart';

Future<DailyReadingStats> computeReadingDay(List<Map<String, dynamic>> rows) =>
    backgroundCompute(
      _readingDay,
      rows,
      enabled: rows.length >= backgroundListThreshold,
    );

DailyReadingStats _readingDay(List<Map<String, dynamic>> rows) =>
    aggregateReadingDays(
      rows.map(
        (r) => ReadingSegment(
          id: r['id'] as String,
          sessionId: r['session_id'] as String,
          runId: r['run_id'] as String,
          startTickMs: r['start_tick_ms'] as int,
          endTickMs: r['end_tick_ms'] as int,
          startUtc: DateTime.parse(r['start_utc'] as String),
          endUtc: DateTime.parse(r['end_utc'] as String),
          localDate: r['local_date'] as String,
          offsetMinutes: r['offset_minutes'] as int,
          mode: ReadingMode.values.byName(r['mode'] as String),
        ),
      ),
    ).single;

typedef PreparedStatistics = (
  ReadingStatisticsSummary,
  ReadingStatisticsSummary,
);

Future<PreparedStatistics> prepareStatistics(
  ReadingStatistics data,
  bool includeAudio,
) => backgroundCompute(_prepareStatistics, (
  data,
  DateTime.now(),
  includeAudio,
), enabled: data.days.length + data.segments.length >= backgroundListThreshold);

PreparedStatistics _prepareStatistics(
  (ReadingStatistics, DateTime, bool) input,
) {
  final (data, now, includeAudio) = input;
  final all = ReadingStatisticsSummary(data, now)..prepare();
  final overview =
      includeAudio
            ? all
            : ReadingStatisticsSummary(
                ReadingStatistics(
                  days: data.days.map(
                    (d) => DailyReadingStats(
                      date: d.date,
                      visualMs: d.visualMs,
                      audioMs: d.audioMs,
                      totalMs: d.visualMs,
                    ),
                  ),
                  sessions: data.sessions,
                  segments: data.segments,
                ),
                now,
              )
        ..prepare();
  return (all, overview);
}

Future<Map<String, DailyReadingStats>> readingBooksOn(
  ReadingStatistics data,
  String date,
) => backgroundCompute(_booksOn, (
  data,
  date,
), enabled: data.segments.length >= backgroundListThreshold);
Map<String, DailyReadingStats> _booksOn((ReadingStatistics, String) input) =>
    ReadingStatisticsSummary(
      input.$1,
      DateTime.parse(input.$2),
    ).booksOn(input.$2);

Future<AchievementFacts> computeAchievementFacts(
  ReadingStatistics data,
  List<BookCompletion> completions,
) => backgroundCompute(_achievementFacts, (
  data,
  completions,
), enabled: data.days.length + completions.length >= backgroundListThreshold);
AchievementFacts _achievementFacts(
  (ReadingStatistics, List<BookCompletion>) input,
) {
  final result = AchievementFacts(statistics: input.$1, completions: input.$2);
  for (final metric in AchievementMetric.values) {
    result.value(metric);
  }
  return result;
}
