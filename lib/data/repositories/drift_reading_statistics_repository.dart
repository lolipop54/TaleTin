import 'package:drift/drift.dart';
import '../../domain/models/reading_statistics.dart';
import '../../domain/repositories/reading_statistics_repository.dart';
import '../database/app_database.dart';
import '../../domain/services/reading_statistics_aggregation.dart';

class DriftReadingStatisticsRepository implements ReadingStatisticsRepository {
  DriftReadingStatisticsRepository(this.db);
  final AppDatabase db;

  @override
  Future<void> save(List<ReadingSession> sessions, List<ReadingSegment> segments) async {
    await db.transaction(() async {
      for (final s in sessions) {
        await db.customStatement('''INSERT INTO reading_sessions
          (id,book_id,mode,started_utc,ended_utc,end_reason) VALUES(?,?,?,?,?,?)
          ON CONFLICT(id) DO UPDATE SET ended_utc=COALESCE(excluded.ended_utc,ended_utc),
          end_reason=COALESCE(excluded.end_reason,end_reason)''',
          [s.id,s.bookId,s.mode.name,s.startedUtc.toIso8601String(),
            s.endedUtc?.toIso8601String(),s.endReason]);
      }
      for (final s in segments) {
        await db.customStatement('''INSERT OR IGNORE INTO reading_segments
          (id,session_id,run_id,start_tick_ms,end_tick_ms,start_utc,end_utc,
           local_date,offset_minutes,mode,active_ms) VALUES(?,?,?,?,?,?,?,?,?,?,?)''',
          [s.id,s.sessionId,s.runId,s.startTickMs,s.endTickMs,
            s.startUtc.toIso8601String(),s.endUtc.toIso8601String(),
            s.localDate,s.offsetMinutes,s.mode.name,s.activeMs]);
      }
      // 从已提交片段计算，重复提交不能再次增加累计值。
      for (final id in {...sessions.map((s) => s.id), ...segments.map((s) => s.sessionId)}) {
        await db.customStatement('''UPDATE reading_sessions SET active_ms=
          (SELECT COALESCE(SUM(active_ms),0) FROM reading_segments WHERE session_id=?)
          WHERE id=?''', [id,id]);
      }
      await _rebuildDays(segments.map((s) => s.localDate).toSet());
    });
    db.notifyUpdates({const TableUpdate('reading_segments')});
  }

  @override
  Future<void> closeInterrupted() async {
    // 不拿启动时间补尾巴，结束点只取已保存的片段；没有片段的会话仍为零。
    await db.transaction(() async {
      await db.customStatement('''UPDATE reading_sessions SET ended_utc=COALESCE(
      (SELECT end_utc FROM reading_segments WHERE session_id=reading_sessions.id
       ORDER BY end_tick_ms DESC LIMIT 1),started_utc), end_reason='interrupted',
      active_ms=(SELECT COALESCE(SUM(active_ms),0) FROM reading_segments
        WHERE session_id=reading_sessions.id) WHERE ended_utc IS NULL''');
      final days = await db.customSelect('SELECT DISTINCT local_date FROM reading_segments').get();
      await db.customStatement('DELETE FROM daily_stats');
      await _rebuildDays(days.map((r) => r.read<String>('local_date')));
    });
  }

  Future<void> _rebuildDays(Iterable<String> dates) async {
    for (final date in dates) {
      final rows = await db.customSelect('SELECT * FROM reading_segments WHERE local_date=?',
        variables: [Variable.withString(date)]).get();
      final day = aggregateReadingDays(rows.map(_segment)).single;
      await db.customStatement('''INSERT OR REPLACE INTO daily_stats
        (local_date,visual_ms,audio_ms,total_union_ms) VALUES(?,?,?,?)''',
        [date,day.visualMs,day.audioMs,day.totalMs]);
    }
  }

  ReadingSegment _segment(QueryRow r) => ReadingSegment(id: r.read('id'),
    sessionId: r.read('session_id'), runId: r.read('run_id'),
    startTickMs: r.read('start_tick_ms'), endTickMs: r.read('end_tick_ms'),
    startUtc: DateTime.parse(r.read('start_utc')), endUtc: DateTime.parse(r.read('end_utc')),
    localDate: r.read('local_date'), offsetMinutes: r.read('offset_minutes'),
    mode: ReadingMode.values.byName(r.read('mode')));

  @override
  Future<ReadingStatistics> load() => db.transaction(() async {
    final sessions = await db.customSelect('SELECT * FROM reading_sessions').get();
    final segments = await db.customSelect('SELECT * FROM reading_segments').get();
    final days = await db.customSelect('SELECT * FROM daily_stats ORDER BY local_date').get();
    return ReadingStatistics(
      days: days.map((r) => DailyReadingStats(date: r.read('local_date'),
        visualMs: r.read('visual_ms'), audioMs: r.read('audio_ms'),
        totalMs: r.read('total_union_ms'))),
      sessions: sessions.map((r) => ReadingSession(id: r.read('id'),
        bookId: r.read('book_id'), mode: ReadingMode.values.byName(r.read('mode')),
        startedUtc: DateTime.parse(r.read('started_utc')),
        endedUtc: r.readNullable<String>('ended_utc') == null ? null
          : DateTime.parse(r.read('ended_utc')), activeMs: r.read('active_ms'),
        endReason: r.readNullable('end_reason'))),
      segments: segments.map(_segment),
    );
  });

  @override
  Stream<ReadingStatistics> watch() => Stream.multi((out) {
    Future<void> pending = Future.value();
    void refresh() {
      pending = pending.then((_) async { out.add(await load()); })
        .catchError((Object e, StackTrace s) { out.addError(e, s); });
    }
    final sub = db.tableUpdates(const TableUpdateQuery.onTableName('reading_segments'))
      .listen((_) => refresh());
    refresh();
    out.onCancel = sub.cancel;
  });
}
