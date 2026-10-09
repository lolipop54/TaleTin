/// 墙上时间仅用于日期标签；持续时间和重叠去重使用同一次运行的单调时间。
abstract interface class ReadingClock {
  ClockSample sample();
}

class ClockSample {
  const ClockSample(this.utc, this.offsetMinutes, this.tickMs);
  final DateTime utc;
  final int offsetMinutes, tickMs;

  DateTime get local => utc.add(Duration(minutes: offsetMinutes));
}

class SystemReadingClock implements ReadingClock {
  final _watch = Stopwatch()..start();
  @override
  ClockSample sample() {
    final now = DateTime.now();
    return ClockSample(
      now.toUtc(),
      now.timeZoneOffset.inMinutes,
      _watch.elapsedMilliseconds,
    );
  }
}
