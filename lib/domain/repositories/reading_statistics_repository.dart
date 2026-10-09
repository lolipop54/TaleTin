import '../models/reading_statistics.dart';

abstract interface class ReadingStatisticsRepository {
  /// 一次提交原子写入；片段 ID 在提交前固定，失败后原样重试。
  Future<void> save(
    List<ReadingSession> sessions,
    List<ReadingSegment> segments,
  );
  Future<void> closeInterrupted();
  Future<ReadingStatistics> load();
  Stream<ReadingStatistics> watch();
}
