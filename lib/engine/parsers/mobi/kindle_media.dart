/// 两种 Kindle 正文使用各自的媒体类型。只改媒体条件最外层的类型名。
String kindleMedia(
  String source, {
  required bool kf8,
  bool stylesheet = false,
}) {
  if (!source.toLowerCase().contains('amzn-')) return source;
  final output = StringBuffer();
  var query = !stylesheet, depth = 0, copied = 0, i = 0;
  bool identifier(int c) =>
      c == 45 ||
      c == 95 ||
      c >= 128 ||
      (c >= 48 && c <= 57) ||
      (c >= 65 && c <= 90) ||
      (c >= 97 && c <= 122);
  while (i < source.length) {
    final c = source.codeUnitAt(i);
    if (c == 47 && source.startsWith('/*', i)) {
      final end = source.indexOf('*/', i + 2);
      i = end < 0 ? source.length : end + 2;
    } else if (c == 34 || c == 39) {
      i++;
      while (i < source.length) {
        final next = source.codeUnitAt(i++);
        if (next == c) break;
        if (next == 92 && i < source.length) i++;
      }
    } else if (c == 64 && stylesheet) {
      final start = ++i;
      while (i < source.length && identifier(source.codeUnitAt(i))) {
        i++;
      }
      final rule = source.substring(start, i).toLowerCase();
      query = rule == 'media' || rule == 'import';
      depth = 0;
    } else if (query && identifier(c)) {
      final start = i++;
      while (i < source.length && identifier(source.codeUnitAt(i))) {
        i++;
      }
      if (depth != 0) continue;
      final word = source.substring(start, i).toLowerCase();
      if (word != 'amzn-kf8' && word != 'amzn-mobi') continue;
      output.write(source.substring(copied, start));
      output.write(
        (word == 'amzn-kf8') == kf8
            ? 'screen'
            : 'taletin-${word.substring(5)}-disabled',
      );
      copied = i;
    } else {
      if (query) {
        if (c == 40) depth++;
        if (c == 41 && depth > 0) depth--;
        if (stylesheet && depth == 0 && (c == 123 || c == 59)) query = false;
      }
      i++;
    }
  }
  if (copied == 0) return source;
  return (output..write(source.substring(copied))).toString();
}
