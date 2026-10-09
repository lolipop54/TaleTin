import '../models/reading_statistics.dart';

/// 跨进程不能比较 Stopwatch 坐标；不同 runId 的有效区间自然互不同时存在。
/// UTC 可能被校时回拨，只用于日期，绝不能用于这里的并集计算。
int readingUnionMs(Iterable<ReadingSegment> segments) {
  final runs = <String,List<ReadingSegment>>{};
  for (final s in segments) { (runs[s.runId] ??= []).add(s); }
  var total = 0;
  for (final run in runs.values) {
    run.sort((a,b) => a.startTickMs.compareTo(b.startTickMs));
    int? start, end;
    for (final s in run) {
      if (end == null || s.startTickMs > end) {
        if (start != null) total += end! - start;
        start = s.startTickMs; end = s.endTickMs;
      } else if (s.endTickMs > end) { end = s.endTickMs; }
    }
    if (start != null) total += end! - start;
  }
  return total;
}

List<DailyReadingStats> aggregateReadingDays(Iterable<ReadingSegment> segments) {
  final dates = <String,List<ReadingSegment>>{};
  for (final s in segments) { (dates[s.localDate] ??= []).add(s); }
  final days = dates.entries.map((e) => DailyReadingStats(date: e.key,
    visualMs: readingUnionMs(e.value.where((s) => s.mode == ReadingMode.visual)),
    audioMs: readingUnionMs(e.value.where((s) => s.mode == ReadingMode.audio)),
    totalMs: readingUnionMs(e.value))).toList();
  days.sort((a,b) => a.date.compareTo(b.date));
  return days;
}
