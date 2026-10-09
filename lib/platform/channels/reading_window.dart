import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 每个功能只释放自己的常亮请求，其他功能仍需要时不关闭窗口常亮。
class ReadingWindow {
  final _owners = <Object>{};
  final exiting = ValueNotifier(false);
  void enterReading() => exiting.value = false;
  Future<void> prepareExit() async {
    exiting.value = true;
    await systemBars(status: true, navigation: true, waitForInsets: true);
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
