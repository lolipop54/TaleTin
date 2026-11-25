import 'dart:io';

import 'package:flutter/services.dart';

/// Android 系统短提示，不占用页面布局。
abstract final class SystemToast {
  static const _channel = MethodChannel('gtreader/toast');

  static Future<void> show(String message) =>
      Platform.isWindows ? Future.value() : _channel.invokeMethod<void>('show', message);

  /// 错误包含可截图反馈的编号，使用系统较长的显示时间。
  static Future<void> showError(String message) =>
      Platform.isWindows ? Future.value() : _channel.invokeMethod<void>('showError', message);

  static Future<void> cancel() =>
      Platform.isWindows ? Future.value() : _channel.invokeMethod<void>('cancel');
}
