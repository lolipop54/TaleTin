// Copyright (c) 2026 GT Reader contributors. MIT license, see LICENSE.
/// Four independent switches used by the isolated, same-APK ablation experiment.
/// Normal builds always enable all optimizations; they cannot change this mask.
abstract final class ProcessingFeatures {
  static const experiments = bool.fromEnvironment('GT_PROCESSING_EXPERIMENT');
  static int _mask = 15;
  static int get mask => experiments ? _mask : 15;
  static bool get nativeHash => mask & 1 != 0;
  static bool get rawHtml => mask & 2 != 0;
  static bool get htmlAllocations => mask & 4 != 0;
  static bool get nativeInflate => mask & 8 != 0;

  /// Also called at worker startup because isolates do not share Dart statics.
  static void configureExperiment(int mask) {
    if (!experiments) return;
    if (mask < 0 || mask > 15) throw ArgumentError.value(mask, 'mask');
    _mask = mask;
  }
}
