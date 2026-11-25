import 'package:flutter/painting.dart';

import '../../domain/models/reading_settings.dart';
import 'layout_options.dart';

final _curves = Expando<List<double>>();

List<double>? pageScaleSamples(TextScaler scaler) {
  final factor = scaler.scale(1);
  if (factor == scaler.scale(32) / 32 && factor == scaler.scale(100) / 100) {
    return null;
  }
  return _curves[scaler] ??= List.unmodifiable([
    for (var i = 0; i <= 128; i++) scaler.scale(i.toDouble()),
  ]);
}

Map<String, dynamic> encodePageOptions(LayoutOptions options) {
  final scaler = options.textScaler;
  // 非线性系统曲线按整数字号采样；默认线性缩放只传一个数。
  final sizes = pageScaleSamples(scaler);
  return {
    'settings': options.settings.toJson(),
    'w': options.contentWidth,
    'h': options.contentHeight,
    'x': options.paperInset.dx,
    'y': options.paperInset.dy,
    'bottom': options.paperBottomInset,
    'dark': options.cssDark,
    'title': options.insertChapterTitle,
    'spread': options.spreadDocumentChapters,
    'scale': scaler.scale(1),
    'sizes': ?sizes,
  };
}

LayoutOptions decodePageOptions(Map<String, dynamic> data) => LayoutOptions(
  settings: ReadingSettings.fromJson(data['settings']),
  contentSize: Size(data['w'], data['h']),
  paperInset: Offset(data['x'], data['y']),
  paperBottomInset: data['bottom'],
  cssDark: data['dark'],
  insertChapterTitle: data['title'],
  spreadDocumentChapters: data['spread'],
  textScaler: data['sizes'] == null
      ? TextScaler.linear(data['scale'])
      : _PageTextScaler((data['sizes'] as List).cast<double>()),
);

class _PageTextScaler extends TextScaler {
  const _PageTextScaler(this.sizes);
  final List<double> sizes;
  @override
  double scale(double size) {
    final last = sizes.length - 1;
    if (size >= last) return size * sizes[last] / last;
    final i = size.floor();
    return sizes[i] + (sizes[i + 1] - sizes[i]) * (size - i);
  }

  @override
  double get textScaleFactor => scale(14) / 14;
}
