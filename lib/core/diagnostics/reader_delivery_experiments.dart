/// 消融只允许诊断构建切换，正式包没有运行时开关或界面设置。
abstract final class ReaderDeliveryExperiments {
  static const _enabled = bool.fromEnvironment('GT_DELIVERY_EXPERIMENT');
  static const _variant = String.fromEnvironment(
    'GT_DELIVERY_VARIANT',
    defaultValue: 'all',
  );
  static String? _runtimeVariant;
  static void configure(String variant) {
    if (!_enabled) throw StateError('仅诊断构建允许选择消融条件');
    _runtimeVariant = variant;
  }

  // 简短名称避免Android单行日志截断。只在诊断构建使用，业务包固定开启保留项。
  static const _prior = {
    'target',
    'incremental',
    'original',
    'priority',
    'configure',
    'checkpoint',
    'startup',
    'demand',
    'markers',
  };
  static bool _has(String feature) {
    final variant = _runtimeVariant ?? _variant;
    if (!_enabled || variant == 'all') return true;
    final stage = switch (variant) {
      'stage0' => 0,
      'stage1' => 1,
      'stage2' => 2,
      'stage3' => 3,
      'stage4' => 4,
      'stageA' => 5,
      _ => null,
    };
    if (stage != null) {
      return switch (feature) {
        'handover' => stage >= 1,
        'parallelOpen' => stage >= 2,
        'pagedShell' => stage >= 3,
        'finalLayout' => stage >= 4,
        'repeatView' => stage >= 5,
        _ => true,
      };
    }
    if (variant == 'prior' || variant == 'cache' || variant == 'native') {
      return _prior.contains(feature) ||
          (variant == 'cache' && feature == 'prepared') ||
          (variant == 'native' && feature == 'nativeResources');
    }
    return variant.split(',').contains(feature);
  }

  static bool get contentTarget => _has('target');
  static bool get incremental => _has('incremental');
  static bool get originalWindow => _has('original');
  static bool get originalPriority => _has('priority');
  static bool get originalConfigure => _has('configure');
  static bool get checkpoint => _has('checkpoint');
  static bool get originalStartup => _has('startup');
  static bool get checkpointDemand => _has('demand');
  static bool get originalMarkers => _has('markers');
  static bool get originalPrepared => _has('prepared');
  static bool get originalNativeResources => _has('nativeResources');
  static bool get originalNavigation => _has('handover');
  static bool get originalParallelOpen => _has('parallelOpen');
  static bool get originalPagedShell => _has('pagedShell');
  static bool get originalFinalLayout => _has('finalLayout');
  static bool get originalRepeatView => _has('repeatView');
}
