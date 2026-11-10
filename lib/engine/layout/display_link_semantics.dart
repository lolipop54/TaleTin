import '../../domain/models/display_source_index.dart';

/// 纯链接段落的排版身份取自a[href]，地址解析失败不应额外产生首行缩进。
abstract final class DisplayLinkSemantics {
  static final _ranges = Expando<Map<int, List<DisplayTextRange>>>();
  static bool onlyLinks(
    DisplaySourceIndex? source,
    int? block,
    int from,
    String text,
  ) {
    if (source == null || block == null) return false;
    final ranges = (_ranges[source] ??= _index(source))[block] ?? const [];
    var i = 0;
    for (final character in RegExp(r'\S').allMatches(text)) {
      final at = from + character.start;
      while (i < ranges.length && ranges[i].end <= at) {
        i++;
      }
      if (i == ranges.length || ranges[i].start > at) return false;
    }
    return ranges.isNotEmpty;
  }

  static Map<int, List<DisplayTextRange>> _index(DisplaySourceIndex source) {
    final result = <int, List<DisplayTextRange>>{};
    for (final e in source.elements.where((e) => e.isLink)) {
      for (final range in e.ranges) {
        (result[range.block] ??= []).add(range);
      }
    }
    for (final ranges in result.values) {
      ranges.sort((a, b) => a.start.compareTo(b.start));
    }
    return result;
  }
}
