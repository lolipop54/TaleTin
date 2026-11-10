import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/diagnostics/reader_work_trace.dart';

/// 原生分类占位（物理像素）：状态栏、底部导航栏和挖孔分别下发。
/// 控制层靠它按“分别显示／隐藏系统栏”的开关，只保留对应那一边的留白。
class ReadingBarInsets {
  const ReadingBarInsets({
    this.status = EdgeInsets.zero,
    this.navigation = EdgeInsets.zero,
    this.cutout = EdgeInsets.zero,
  });

  final EdgeInsets status;
  final EdgeInsets navigation;
  final EdgeInsets cutout;

  /// 合成控制层留白：挖孔算在顶部状态栏那一侧，底部导航栏只影响自己那一侧。
  /// 隐藏哪个系统栏，对应那一边就归零；两个都不显示时等于没有留白。
  EdgeInsets controls({required bool statusBar, required bool navigationBar}) {
    double side(double status, double nav, double cutout) => math.max(
      statusBar ? math.max(status, cutout) : 0,
      navigationBar ? nav : 0,
    );
    return EdgeInsets.fromLTRB(
      side(status.left, navigation.left, cutout.left),
      statusBar ? math.max(status.top, cutout.top) : 0,
      side(status.right, navigation.right, cutout.right),
      navigationBar ? navigation.bottom : 0,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ReadingBarInsets &&
      other.status == status &&
      other.navigation == navigation &&
      other.cutout == cutout;

  @override
  int get hashCode => Object.hash(status, navigation, cutout);
}

/// 每个功能只释放自己的常亮请求，其他功能仍需要时不关闭窗口常亮。
class ReadingWindow {
  final _owners = <Object>{};
  final exiting = ValueNotifier(false);
  bool _globalLandscape = false;
  bool? _appliedLandscape;
  Object? _readerOwner;

  /// 最近一次读取的分类系统占位；为空表示平台不支持或还没读到。
  final barInsets = ValueNotifier<ReadingBarInsets?>(null);

  Future<void> refreshBarInsets() async {
    try {
      final next = _readBarInsets(
        await channel.invokeMethod<Object?>('barInsets'),
      );
      if (next != null) barInsets.value = next;
    } on MissingPluginException {
      // 非 Android 或组件测试：保持为空，界面退回按系统栏开关使用整块安全区。
    } on PlatformException {
      // 读取失败时沿用上一次的占位，不阻塞阅读。
    }
  }

  static ReadingBarInsets? _readBarInsets(Object? raw) {
    if (raw is! Map) return null;
    return ReadingBarInsets(
      status: _insetsOf(raw['status']),
      navigation: _insetsOf(raw['navigation']),
      cutout: _insetsOf(raw['cutout']),
    );
  }

  static EdgeInsets _insetsOf(Object? raw) {
    if (raw is! Map) return EdgeInsets.zero;
    double side(String key) => (raw[key] as num?)?.toDouble() ?? 0;
    return EdgeInsets.fromLTRB(
      side('left'),
      side('top'),
      side('right'),
      side('bottom'),
    );
  }

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
      // 显示／隐藏后各边的实际占位会变，控制层需要按新的开关重新取一次。
      await refreshBarInsets();
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
