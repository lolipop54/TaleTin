/// 与 ReadingStatisticsSummary.latest 的 04:00 阅读夜规则一致。
/// 分钟直接取 ISO 日期字段并应用片段自身的偏移，不用 SQLite 的毫秒舍入，
/// 避免 03:59:59.999999 被进位到 04:00。片段已按本地午夜拆分。
const latestReadingSegmentQuery = '''
WITH clocks AS (
  SELECT rowid AS source_order, *,
    ((CAST(substr(start_utc,12,2) AS INTEGER)*60 +
      CAST(substr(start_utc,15,2) AS INTEGER)+offset_minutes)%1440+1440)%1440 AS start_minute,
    ((CAST(substr(end_utc,12,2) AS INTEGER)*60 +
      CAST(substr(end_utc,15,2) AS INTEGER)+offset_minutes)%1440+1440)%1440 AS end_minute,
    substr(replace(substr(end_utc,21),'Z','') || '000000',1,6) AS end_fraction
  FROM reading_segments
), ranked AS (
  SELECT *,
    CASE WHEN start_minute<240 AND end_minute>=240 THEN 100799999
      ELSE ((end_minute + CASE WHEN end_minute<240 THEN 1440 ELSE 0 END)*60
        + CAST(substr(end_utc,18,2) AS INTEGER))*1000
        + CAST(substr(end_fraction,1,3) AS INTEGER) END AS night_ms,
    CASE WHEN start_minute<240 AND end_minute>=240 THEN local_date
      WHEN end_minute<start_minute THEN date(local_date,'+1 day')
      ELSE local_date END AS candidate_date,
    CASE WHEN start_minute<240 AND end_minute>=240 THEN '999000'
      ELSE end_fraction END AS candidate_fraction
  FROM clocks
)
SELECT * FROM ranked
ORDER BY night_ms DESC, candidate_date DESC, candidate_fraction DESC, source_order ASC LIMIT 1
''';
