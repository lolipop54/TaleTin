/// [FontResolver] 的 Android 实现，包装设备能力通道。
library;

import 'package:flutter/services.dart';

import '../../domain/services/font_resolver.dart';
import 'document_host_api.g.dart' as pigeon;

class AndroidFontResolver implements FontResolver {
  AndroidFontResolver({pigeon.DeviceHostApi? api})
      : _api = api ?? pigeon.DeviceHostApi();

  final pigeon.DeviceHostApi _api;

  @override
  Future<Map<String, String?>> resolve(List<String> families) async {
    if (families.isEmpty) return const {};
    try {
      final results = await _api.resolveFontFamilies(families);
      return {
        for (final dto in results) dto.requested: dto.resolved,
      };
    } on MissingPluginException {
      // 平台没接这条通道（测试、桌面端）时按「解析不出来」处理
      return const {};
    } on PlatformException {
      return const {};
    }
  }
}
