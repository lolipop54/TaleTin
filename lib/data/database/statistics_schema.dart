import 'package:drift/drift.dart';

/// 统计历史不随书籍内容删除；沿用书籍墓碑 ID，不设置级联删除。
/// 使用独立 SQL 表避免生成层暴露给领域；读写集中在统计仓库。
Future<void> createStatisticsSchema(GeneratedDatabase db) async {
  await db.customStatement('''CREATE TABLE reading_sessions (
    id TEXT PRIMARY KEY NOT NULL, book_id TEXT NOT NULL, mode TEXT NOT NULL,
    started_utc TEXT NOT NULL, ended_utc TEXT, active_ms INTEGER NOT NULL DEFAULT 0,
    end_reason TEXT)''');
  await db.customStatement('''CREATE TABLE reading_segments (
    id TEXT PRIMARY KEY NOT NULL,
    session_id TEXT NOT NULL REFERENCES reading_sessions(id),
    run_id TEXT NOT NULL, start_tick_ms INTEGER NOT NULL,
    end_tick_ms INTEGER NOT NULL, start_utc TEXT NOT NULL, end_utc TEXT NOT NULL,
    local_date TEXT NOT NULL, offset_minutes INTEGER NOT NULL,
    mode TEXT NOT NULL, active_ms INTEGER NOT NULL CHECK(active_ms > 0))''');
  await db.customStatement('CREATE INDEX idx_segments_day ON reading_segments(local_date)');
  await db.customStatement('CREATE INDEX idx_segments_session ON reading_segments(session_id)');
  await db.customStatement('''CREATE TABLE daily_stats (
    local_date TEXT PRIMARY KEY NOT NULL, visual_ms INTEGER NOT NULL,
    audio_ms INTEGER NOT NULL, total_union_ms INTEGER NOT NULL)''');
}
