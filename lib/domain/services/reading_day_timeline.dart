import '../models/reading_statistics.dart';
import 'reading_statistics_aggregation.dart';

/// 一次会话在选中自然日的真实有效片段，不用会话墙上时间推算时长。
class ReadingDayEntry {
  const ReadingDayEntry(
    this.bookId,
    this.mode,
    this.start,
    this.end,
    this.activeMs,
  );
  final String bookId;
  final ReadingMode mode;
  final DateTime start, end;
  final int activeMs;
}

List<ReadingDayEntry> readingDayTimeline(ReadingStatistics data, String date) {
  final sessions = {for (final s in data.sessions) s.id: s};
  final groups = <String, List<ReadingSegment>>{};
  for (final s in data.segments.where((s) => s.localDate == date)) {
    (groups[s.sessionId] ??= []).add(s);
  }
  final entries = <ReadingDayEntry>[];
  for (final group in groups.entries) {
    final session = sessions[group.key]!;
    final pieces = group.value
      ..sort((a, b) => a.startUtc.compareTo(b.startUtc));
    final first = pieces.first;
    final last = pieces.reduce((a, b) => a.endUtc.isAfter(b.endUtc) ? a : b);
    entries.add(
      ReadingDayEntry(
        session.bookId,
        session.mode,
        first.startUtc.add(Duration(minutes: first.offsetMinutes)),
        last.endUtc.add(Duration(minutes: last.offsetMinutes)),
        readingUnionMs(pieces),
      ),
    );
  }
  entries.sort((a, b) => a.start.compareTo(b.start));
  return entries;
}
