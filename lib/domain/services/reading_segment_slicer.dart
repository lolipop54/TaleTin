import '../models/reading_statistics.dart';
import 'reading_clock.dart';

String readingDate(DateTime local) => local.toIso8601String().substring(0, 10);

/// 一次采样到下一次采样之间沿旧墙钟映射推进。校时/换时区在下一采样生效，
/// 两种模式共用切点；不回拨单调坐标，也不把时钟跳跃当成阅读时长。
Iterable<ReadingSegment> sliceReading({required ReadingSession session,
  required String runId, required ClockSample start, required int endTickMs,
  required String Function() newId}) sync* {
  var tick = start.tickMs;
  // 持久化和切点统一到毫秒，午夜前不足 1ms 不得形成零长度死循环。
  var utc = DateTime.fromMillisecondsSinceEpoch(start.utc.millisecondsSinceEpoch, isUtc: true);
  while (tick < endTickMs) {
    final local = utc.add(Duration(minutes: start.offsetMinutes));
    final midnight = DateTime.utc(local.year,local.month,local.day + 1);
    final remaining = endTickMs - tick;
    final untilMidnight = midnight.difference(local).inMilliseconds;
    final length = remaining < untilMidnight ? remaining : untilMidnight;
    final end = utc.add(Duration(milliseconds: length));
    yield ReadingSegment(id: newId(),sessionId: session.id,runId: runId,
      startTickMs: tick,endTickMs: tick + length,startUtc: utc,endUtc: end,
      localDate: readingDate(local),offsetMinutes: start.offsetMinutes,mode: session.mode);
    tick += length;
    utc = end;
  }
}
