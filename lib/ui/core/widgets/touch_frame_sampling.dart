import 'package:flutter/widgets.dart';

/// Flutter 的触摸重采样对整个应用生效。页面转场时，新旧页面可能短暂同时挂载。
/// 最后一个使用者离开时才恢复原设置，避免退出阅读页时关掉书架正在使用的采样。
class TouchFrameSampling {
  static final _requests = <TouchFrameSampling, bool>{};
  static late bool _previousEnabled;
  static late Duration _previousOffset;

  void acquire({bool enabled = true}) {
    if (_requests[this] == enabled) return;
    final binding = WidgetsBinding.instance;
    if (_requests.isEmpty) {
      _previousEnabled = binding.resamplingEnabled;
      _previousOffset = binding.samplingOffset;
    }
    _requests[this] = enabled;
    _apply(binding);
  }

  void release() {
    if (_requests.remove(this) != null) _apply(WidgetsBinding.instance);
  }

  static void _apply(WidgetsBinding binding) {
    // 阅读诊断包可以显式关闭采样，即使书架仍在完成退出动画也要遵守。
    binding
      ..samplingOffset = _requests.isEmpty
          ? _previousOffset
          : const Duration(milliseconds: -8)
      ..resamplingEnabled = _requests.isEmpty
          ? _previousEnabled
          : !_requests.containsValue(false);
  }
}
