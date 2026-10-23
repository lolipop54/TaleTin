import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/diagnostics/reader_work_trace.dart';

/// 每个功能只释放自己的常亮请求，其他功能仍需要时不关闭窗口常亮。
class ReadingWindow {
  final _owners = <Object>{};
  final exiting = ValueNotifier(false);
  bool _globalLandscape = false;
  bool? _appliedLandscape;
  Object? _readerOwner;

  static List<DeviceOrientation> orientations(bool landscape) => landscape
      ? [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]
      : [DeviceOrientation.portraitUp];

  Future<void> _orient(bool landscape) async {
    if (_appliedLandscape == landscape) return;
    _appliedLandscape = landscape;
    await SystemChrome.setPreferredOrientations(orientations(landscape));
  }

  /// 全局设置控制书架等页面；阅读期间由当前书的有效设置接管方向。
  Future<void> setGlobalLandscape(bool value) async {
    _globalLandscape = value;
    if (_readerOwner == null || exiting.value) await _orient(value);
  }

  void enterReading([Object? owner]) {
    _readerOwner = owner ?? this;
    exiting.value = false;
  }

  Future<void> setReaderLandscape(Object owner, bool value) async {
    if (_readerOwner == owner && !exiting.value) await _orient(value);
  }

  Future<void> leaveReading(Object owner) async {
    // 换书时旧页面可能比新页面晚释放，不能让旧页面恢复方向覆盖新书。
    if (_readerOwner != owner) return;
    _readerOwner = null;
    await _orient(_globalLandscape);
  }

  Future<void> prepareExit() async {
    exiting.value = true;
    await traceReaderWork(
      'reader.exit.window.orientation',
      () => _orient(_globalLandscape),
    );
    await traceReaderWork(
      'reader.exit.window.system_bars',
      () => systemBars(status: true, navigation: true, waitForInsets: true),
    );
  }

  static const channel = MethodChannel('gtreader/reading_window');
  Future<void> systemBars({
    required bool status,
    required bool navigation,
    bool waitForInsets = false,
  }) async {
    try {
      await channel.invokeMethod<void>('systemBars', {
        'status': exiting.value || status,
        'navigation': exiting.value || navigation,
        'waitForInsets': waitForInsets,
        'trace': readerWorkTraceEnabled,
      });
    } on MissingPluginException {
      /* 非 Android 无系统栏接管。 */
    }
  }

  Future<void> volumeKeys(bool enabled) async {
    try {
      await channel.invokeMethod<void>('volumeKeys', enabled);
    } on MissingPluginException {
      /* 非 Android 测试不接管实体按键。 */
    }
  }

  Future<void> keepAwake(Object owner, bool enabled) async {
    if (enabled) {
      _owners.add(owner);
    } else {
      _owners.remove(owner);
    }
    try {
      await channel.invokeMethod<void>('keepAwake', _owners.isNotEmpty);
    } on MissingPluginException {
      // 桌面/组件测试没有 Android 窗口，阅读逻辑仍可正常运行。
    }
  }
}

final readingWindowProvider = Provider((ref) => ReadingWindow());
