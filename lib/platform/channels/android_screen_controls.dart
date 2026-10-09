/// [ScreenControls] 的 Android 实现，包装设备能力通道。
library;

import 'package:flutter/services.dart';

import '../../domain/services/screen_controls.dart';
import 'document_host_api.g.dart' as pigeon;

class AndroidScreenControls implements ScreenControls {
  AndroidScreenControls({pigeon.DeviceHostApi? api})
      : _api = api ?? pigeon.DeviceHostApi();

  final pigeon.DeviceHostApi _api;

  @override
  Future<void> setWindowBrightness(double? value) async {
    try {
      await _api.setWindowBrightness(value);
    } on MissingPluginException {
      // 平台没接这条通道（测试、桌面端）：什么都不做
    } on PlatformException {
      // 窗口属性设置失败不影响阅读
    }
  }

  @override
  Future<double?> systemBrightness() async {
    try {
      return await _api.systemBrightness();
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  @override
  Future<int?> batteryLevel() async {
    try {
      return await _api.batteryLevel();
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }
}
