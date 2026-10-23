import 'dart:io';

import 'package:flutter/services.dart';

import '../../core/diagnostics/reader_delivery_experiments.dart';
import '../../core/diagnostics/reader_work_trace.dart';

/// 只登记已核验资源的路径与会话，不通过通道传回图片字节。
abstract final class OriginalResources {
  static const _channel = MethodChannel('gtreader/original_resources');
  static bool get enabled =>
      Platform.isAndroid && ReaderDeliveryExperiments.originalNativeResources;
  static Future<void> bind(
    Object view,
    String session,
    String prefix,
    Map<String, dynamic> proof, {
    String? injection,
  }) async {
    if (!enabled) return;
    try {
      await _channel.invokeMethod<void>('bind', {
        'view': '$view',
        'session': session,
        'prefix': prefix,
        'proof': proof,
        'injection': injection,
        'trace': readerWorkTraceEnabled,
      });
    } on MissingPluginException {
      /* 非Android测试和旧插件沿用资源回调。 */
    }
  }

  static Future<void> unbind(Object view) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('unbind', {'view': '$view'});
    } on MissingPluginException {
      /* 原路径不依赖此可选能力。 */
    }
  }

  static Future<void> closeSession(String session) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('close', {'session': session});
    } on MissingPluginException {
      /* 无原生登记时无需处理。 */
    }
  }
}
