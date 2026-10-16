/// 只有专项实验包可对比旧／新流程；匹配统一使用 Dart。
abstract final class PositionExperiments {
  static const enabled = bool.fromEnvironment('GT_POSITION_EXPERIMENTS');
  static int _mask = 1;
  static bool get optimizedFlow => !enabled || _mask & 1 != 0;
  static void configure(int mask) {
    if (enabled) _mask = mask;
  }
}
