/// Only explicit experiment builds can select the frozen Dart baseline.
abstract final class OriginalProcessing {
  static const experiment = bool.fromEnvironment('GT_ORIGINAL_EXPERIMENT');
  static int _mode = 1;
  static int get mode => experiment ? _mode : 1;
  static void configure(int mode) {
    if (experiment) _mode = mode;
  }
}
