/// 普通构建固定开启已通过实测的准备优化；隔离诊断包才允许逐项对照。
abstract final class OpeningExperiments {
  static const enabled = bool.fromEnvironment('GT_OPENING_EXPERIMENT');
  static int _candidate = 0;

  static void configure(int candidate) {
    if (enabled) _candidate = candidate;
  }

  static bool get visibleImageDecode => !enabled || _candidate == 3;
  static bool get warmWebView => !enabled || _candidate == 4;
}
