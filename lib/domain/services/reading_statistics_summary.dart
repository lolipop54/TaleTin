import '../models/reading_statistics.dart';
import 'reading_segment_slicer.dart';
import 'reading_statistics_aggregation.dart';

class ReadingStatisticsSummary {
  ReadingStatisticsSummary(this.data,DateTime localNow)
    : today = DateTime.utc(localNow.year,localNow.month,localNow.day);
  final ReadingStatistics data;
  final DateTime today;
  DailyReadingStats day(String date) => data.days.firstWhere((d) => d.date == date,
    orElse: () => DailyReadingStats(date: date));
  int get todayMs => day(readingDate(today)).totalMs;
  int get totalMs => data.days.fold(0,(sum,d) => sum+d.totalMs);
  int get weekMs {
    final monday = readingDate(today.subtract(Duration(days: today.weekday-1)));
    final end = readingDate(today);
    return data.days.where((d) => d.date.compareTo(monday) >= 0 && d.date.compareTo(end) <= 0)
      .fold(0,(sum,d) => sum+d.totalMs);
  }
  int get streak {
    var date = today;
    if (day(readingDate(date)).totalMs < 60000) date = date.subtract(const Duration(days: 1));
    var count = 0;
    while (day(readingDate(date)).totalMs >= 60000) {
      count++; date = date.subtract(const Duration(days: 1));
    }
    return count;
  }
  ReadingSession? get longestSession {
    ReadingSession? result;
    for (final s in data.sessions) {
      if (s.activeMs > (result?.activeMs ?? 0)) result = s;
    }
    return result;
  }
  DailyReadingStats? get longestDay {
    DailyReadingStats? result;
    for (final d in data.days) {
      if (d.totalMs > (result?.totalMs ?? 0)) result = d;
    }
    return result;
  }

  Map<String,DailyReadingStats> booksOn(String date) {
    final books = {for (final s in data.sessions) s.id:s.bookId};
    final pieces = <String,List<ReadingSegment>>{};
    for (final s in data.segments.where((s) => s.localDate == date)) {
      (pieces[books[s.sessionId]!] ??= []).add(s);
    }
    return {for (final e in pieces.entries) e.key:aggregateReadingDays(e.value).single};
  }

  LatestReading? get latest {
    LatestReading? best;
    void candidate(DateTime local) {
      final nextDay = local.hour < 4;
      final date = DateTime.utc(local.year,local.month,local.day)
        .subtract(Duration(days: nextDay ? 1 : 0));
      final value = LatestReading(readingDate(date),local,nextDay);
      if (best == null || value.nightMs > best!.nightMs ||
          (value.nightMs == best!.nightMs && local.isAfter(best!.localEnd))) { best = value; }
    }
    for (final s in data.segments) {
      final offset = Duration(minutes: s.offsetMinutes);
      final start = s.startUtc.add(offset), end = s.endUtc.add(offset);
      final four = DateTime.utc(start.year,start.month,start.day,4);
      // 跨 04:00 的片段同时属于两个阅读夜；上一夜的末尾也参与比较。
      if (start.isBefore(four) && !end.isBefore(four)) {
        candidate(four.subtract(const Duration(milliseconds: 1)));
      }
      if (end != four) candidate(end);
    }
    return best;
  }
}

class LatestReading {
  const LatestReading(this.nightDate,this.localEnd,this.nextDay);
  final String nightDate;
  final DateTime localEnd;
  final bool nextDay;
  int get nightMs => ((localEnd.hour + (nextDay ? 24 : 0))*3600 +
    localEnd.minute*60 + localEnd.second)*1000 + localEnd.millisecond;
}
