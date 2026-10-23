import '../models/reading_statistics.dart';
import 'reading_segment_slicer.dart';
import 'reading_statistics_aggregation.dart';

class ReadingStatisticsSummary {
  ReadingStatisticsSummary(this.data, DateTime localNow)
    : today = DateTime.utc(localNow.year, localNow.month, localNow.day);
  final ReadingStatistics data;
  final DateTime today;
  // 保留 firstWhere 的第一条命中规则；同一快照的日历和连续记录共用此索引。
  late final Map<String, DailyReadingStats> daysByDate = _indexDays();
  Map<String, DailyReadingStats> _indexDays() {
    final result = <String, DailyReadingStats>{};
    for (final day in data.days) {
      result.putIfAbsent(day.date, () => day);
    }
    return result;
  }

  DailyReadingStats day(String date) =>
      daysByDate[date] ?? DailyReadingStats(date: date);
  int get todayMs => day(readingDate(today)).totalMs;
  late final int totalMs = data.days.fold(0, (sum, d) => sum + d.totalMs);
  late final int weekMs = _weekMs();
  int _weekMs() {
    final monday = readingDate(
      today.subtract(Duration(days: today.weekday - 1)),
    );
    final end = readingDate(today);
    return data.days
        .where(
          (d) => d.date.compareTo(monday) >= 0 && d.date.compareTo(end) <= 0,
        )
        .fold(0, (sum, d) => sum + d.totalMs);
  }

  late final int streak = _streak();
  int _streak() {
    var date = today;
    if (day(readingDate(date)).totalMs < 60000) {
      date = date.subtract(const Duration(days: 1));
    }
    var count = 0;
    while (day(readingDate(date)).totalMs >= 60000) {
      count++;
      date = date.subtract(const Duration(days: 1));
    }
    return count;
  }

  late final ReadingSession? longestSession = _longestSession();
  ReadingSession? _longestSession() {
    ReadingSession? result;
    for (final s in data.sessions) {
      if (s.activeMs > (result?.activeMs ?? 0)) result = s;
    }
    return result;
  }

  late final DailyReadingStats? longestDay = _longestDay();
  DailyReadingStats? _longestDay() {
    DailyReadingStats? result;
    for (final d in data.days) {
      if (d.totalMs > (result?.totalMs ?? 0)) result = d;
    }
    return result;
  }

  Map<String, DailyReadingStats> booksOn(String date) {
    final books = {for (final s in data.sessions) s.id: s.bookId};
    final pieces = <String, List<ReadingSegment>>{};
    for (final s in data.segments.where((s) => s.localDate == date)) {
      (pieces[books[s.sessionId]!] ??= []).add(s);
    }
    return {
      for (final e in pieces.entries)
        e.key: aggregateReadingDays(e.value).single,
    };
  }

  late final LatestReading? latest = _latest();
  LatestReading? _latest() {
    LatestReading? best;
    void candidate(DateTime local) {
      final nextDay = local.hour < 4;
      final date = DateTime.utc(
        local.year,
        local.month,
        local.day,
      ).subtract(Duration(days: nextDay ? 1 : 0));
      final value = LatestReading(readingDate(date), local, nextDay);
      if (best == null ||
          value.nightMs > best!.nightMs ||
          (value.nightMs == best!.nightMs && local.isAfter(best!.localEnd))) {
        best = value;
      }
    }

    for (final s in data.segments) {
      final offset = Duration(minutes: s.offsetMinutes);
      final start = s.startUtc.add(offset), end = s.endUtc.add(offset);
      final four = DateTime.utc(start.year, start.month, start.day, 4);
      // 跨 04:00 的片段同时属于两个阅读夜；上一夜的末尾也参与比较。
      if (start.isBefore(four) && !end.isBefore(four)) {
        candidate(four.subtract(const Duration(milliseconds: 1)));
      }
      if (end != four) candidate(end);
    }
    return best;
  }

  /// 在后台交付前完成所有展示计算，build 只读取结果。
  void prepare() {
    daysByDate;
    totalMs;
    weekMs;
    streak;
    longestDay;
    longestSession;
    latest;
  }
}

class LatestReading {
  const LatestReading(this.nightDate, this.localEnd, this.nextDay);
  final String nightDate;
  final DateTime localEnd;
  final bool nextDay;
  int get nightMs =>
      ((localEnd.hour + (nextDay ? 24 : 0)) * 3600 +
              localEnd.minute * 60 +
              localEnd.second) *
          1000 +
      localEnd.millisecond;
}
