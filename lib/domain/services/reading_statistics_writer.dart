import '../models/reading_statistics.dart';
import '../repositories/reading_statistics_repository.dart';

/// 失败保留原对象和 ID。提交中新增的片段留给下一轮，不能被旧提交删掉。
class ReadingStatisticsWriter {
  ReadingStatisticsWriter(this.repository);
  final ReadingStatisticsRepository repository;
  final sessions = <ReadingSession>[];
  final segments = <ReadingSegment>[];
  Future<void>? _pending;
  Object? lastError;

  Future<void> flush() async {
    if (_pending != null) { await _pending; return flush(); }
    if (sessions.isEmpty && segments.isEmpty) return;
    final sentSessions = List<ReadingSession>.of(sessions);
    final sentSegments = List<ReadingSegment>.of(segments);
    final operation = _pending = repository.save(sentSessions, sentSegments);
    try {
      await operation;
      sessions.removeRange(0, sentSessions.length);
      segments.removeRange(0, sentSegments.length);
      lastError = null;
    } catch (e) {
      lastError = e;
      rethrow;
    } finally { _pending = null; }
  }
}
