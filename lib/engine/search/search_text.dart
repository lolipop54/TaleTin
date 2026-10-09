import 'package:characters/characters.dart';

/// 每个搜索 UTF-16 单元保留原文覆盖范围，大小写展开和空白折叠不丢位置。
class SearchText {
  static final _blank = RegExp(r'^\s+$');
  SearchText(String source) {
    final buffer = StringBuffer();
    var offset = 0;
    var whitespace = false;
    for (final cluster in source.characters) {
      final end = offset + cluster.length;
      final blank = _blank.hasMatch(cluster);
      if (blank && whitespace) {
        ends[ends.length - 1] = end;
      } else {
        final value = blank ? ' ' : cluster.toLowerCase();
        buffer.write(value);
        for (var i = 0; i < value.length; i++) {
          starts.add(offset);
          ends.add(end);
        }
      }
      whitespace = blank;
      offset = end;
    }
    text = buffer.toString();
  }
  late final String text;
  final starts = <int>[];
  final ends = <int>[];
}

String normalizeSearchQuery(String query) => SearchText(query).text.trim();
