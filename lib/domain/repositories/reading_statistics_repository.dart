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

  /// 总览复用日汇总，仅带最长会话与最晚记录需要的片段，不是完整历史。
  Future<ReadingStatistics> loadOverview();
  Stream<ReadingStatistics> watchOverview();

  /// 按已保存的本地日期读取明细，范围为 [fromDate, toDate)。
  Future<ReadingStatistics> loadRange(String fromDate, String toDate);
}
