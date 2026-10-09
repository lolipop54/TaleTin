enum ReadingMode { visual, audio }

class ReadingSession {
  const ReadingSession({
    required this.id,
    required this.bookId,
    required this.mode,
    required this.startedUtc,
    this.endedUtc,
    this.activeMs = 0,
    this.endReason,
  });
  final String id, bookId;
  final ReadingMode mode;
  final DateTime startedUtc;
  final DateTime? endedUtc;
  final int activeMs;
  final String? endReason;
}

/// runId 区分进程启动；同一运行中的 tick 可以比较，不能用校时后的 UTC 去重。
class ReadingSegment {
  const ReadingSegment({
    required this.id,
    required this.sessionId,
    required this.runId,
    required this.startTickMs,
    required this.endTickMs,
    required this.startUtc,
    required this.endUtc,
    required this.localDate,
    required this.offsetMinutes,
    required this.mode,
  });
  final String id, sessionId, runId, localDate;
  final int startTickMs, endTickMs, offsetMinutes;
  final DateTime startUtc, endUtc;
  final ReadingMode mode;
  int get activeMs => endTickMs - startTickMs;
}

class DailyReadingStats {
  const DailyReadingStats({
    required this.date,
    this.visualMs = 0,
    this.audioMs = 0,
    this.totalMs = 0,
  });
  final String date;
  final int visualMs, audioMs, totalMs;
}

class ReadingStatistics {
  ReadingStatistics({
    required Iterable<DailyReadingStats> days,
    required Iterable<ReadingSession> sessions,
    required Iterable<ReadingSegment> segments,
  }) : days = List.unmodifiable(days),
       sessions = List.unmodifiable(sessions),
       segments = List.unmodifiable(segments);
  final List<DailyReadingStats> days;
  final List<ReadingSession> sessions;
  final List<ReadingSegment> segments;
}
