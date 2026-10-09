import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import 'turn_trace.dart';

/// 原生画面已就绪后，从正文自己的 Flutter 图层取原尺寸图像。
/// 只负责取图；章节切换、旧页遮盖及三页缓存仍由原来的翻页流程管理。
class OriginalPageCapture {
  OriginalPageCapture(this.boundaryKey);
  final GlobalKey boundaryKey;

  /// 同一流程的软件兼容入口，也供独立验证入口做同包对照。
  static bool softwareOnly = const bool.fromEnvironment('GT_SOFTWARE_CAPTURE');

  /// 仅验证入口登记，用于在目标仍被持有时保存两种路径的画面对照。
  /// 正常 main 不登记，不回读像素、不编码图片，也不保存阅读内容。
  static Future<void> Function(
    String label,
    ui.Image image,
    Future<ui.Image> Function() software,
  )?
  inspect;

  bool _softwareFallback = false;

  Future<ui.Image> capture({
    required double pixelRatio,
    required String label,
    required Future<ui.Image> Function() software,
  }) async {
    final watch = Stopwatch()..start();
    ui.Image? image;
    var frameWaitUs = 0;
    var mode = 'software';
    if (!softwareOnly && !_softwareFallback) {
      try {
        // Android OnDraw 已完成仍不代表 Flutter 消费了新纹理。
        // 主动请求下一帧，不用固定毫秒延时，也不因已有旧图而省掉这一帧。
        await WidgetsBinding.instance.endOfFrame;
        frameWaitUs = watch.elapsedMicroseconds;
        final boundary = boundaryKey.currentContext?.findRenderObject();
        if (boundary is! RenderRepaintBoundary ||
            !boundary.attached ||
            boundary.size.isEmpty) {
          throw StateError('正文截图图层尚未就绪');
        }
        final size = boundary.size;
        image = await boundary.toImage(pixelRatio: pixelRatio);
        if (image.width != (size.width * pixelRatio).ceil() ||
            image.height != (size.height * pixelRatio).ceil()) {
          image.dispose();
          image = null;
          throw StateError('正文截图尺寸不符');
        }
        mode = 'flutter';
      } catch (error) {
        // 本次阅读遇到不支持的图层／取图失败后沿用软件，避免每页重复失败。
        _softwareFallback = true;
        traceTurn('page capture fallback $label type=${error.runtimeType}');
      }
    }
    image ??= await software();
    traceTurn(
      'page capture mode=$mode $label frameWaitUs=$frameWaitUs '
      'totalUs=${watch.elapsedMicroseconds} size=${image.width}x${image.height}',
    );
    final observer = inspect;
    if (observer != null) {
      try {
        await observer(label, image, software);
      } catch (_) {
        image.dispose();
        rethrow;
      }
    }
    return image;
  }
}
