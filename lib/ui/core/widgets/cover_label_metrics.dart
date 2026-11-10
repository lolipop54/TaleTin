import 'package:flutter/painting.dart';

import '../../../domain/models/book.dart';

/// 同尺寸、同字体的格式标签共用一次测量，不随每本书重复排五种文字。
abstract final class CoverLabelMetrics {
  static final _widths = <TextStyle, double>{};
  static bool _listening = false;

  static double width(TextStyle style) {
    if (!_listening) {
      _listening = true;
      PaintingBinding.instance.systemFonts.addListener(_widths.clear);
    }
    final cached = _widths.remove(style);
    if (cached != null) {
      _widths[style] = cached;
      return cached;
    }
    final painter = TextPainter(
      textDirection: TextDirection.ltr,
      textScaler: TextScaler.noScaling,
      maxLines: 1,
    );
    var width = 0.0;
    for (final format in BookFormat.values) {
      painter.text = TextSpan(text: format.label, style: style);
      painter.layout();
      if (painter.width > width) width = painter.width;
    }
    painter.dispose();
    final result = width.ceilToDouble();
    // 只保留近期的字号／字体组合，旋转、改字体不会无限累积。
    if (_widths.length >= 32) _widths.remove(_widths.keys.first);
    _widths[style] = result;
    return result;
  }
}
