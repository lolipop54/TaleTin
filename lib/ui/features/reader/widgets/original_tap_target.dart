import 'dart:ui';

/// 同一网页帧里取得命中结果，避免四次平台往返及期间页面变化。
class OriginalTapTarget {
  OriginalTapTarget(Map<String, dynamic> value)
    : image = value['image'] as String?,
      link = value['link'] as String?,
      highlight = value['highlight'] as String?,
      markers = [
        for (final row in value['markers'] as List)
          (
            id: row['id'] as String,
            rect: Rect.fromLTWH(
              (row['left'] as num).toDouble(),
              (row['top'] as num).toDouble(),
              (row['width'] as num).toDouble(),
              (row['height'] as num).toDouble(),
            ),
          ),
      ];
  final String? image, link, highlight;
  final List<({String id, Rect rect})> markers;
}
