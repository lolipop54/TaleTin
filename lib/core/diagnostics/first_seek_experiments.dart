/// 普通构建固定开启已实测的大章并行，隔离诊断包允许同包对照。
abstract final class FirstSeekExperiments {
  static const enabled = bool.fromEnvironment('GT_FIRST_SEEK_EXPERIMENT');
  static int _candidate = 0;
  static void configure(int candidate) {
    if (enabled) _candidate = candidate;
  }

  static bool get parallelChapter => !enabled || (_candidate & 2) != 0;
}
