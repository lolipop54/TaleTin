/// 正文文本标准化（设计文档 6.3）。
///
/// 口径：连续空白折叠为单个空格、`<br>` 折叠为换行、块首尾空白去除；
/// 所有偏移与长度基于标准化后的文本。
library;

/// 首行缩进前缀：中文正文常用两个全角空格，正文缩进由阅读设置统一渲染，
/// 因此解析时要去掉，避免与自动缩进叠加成四格。
const String kIndentUnit = '\u3000';

/// 折叠行内连续空白为一个半角空格，并去掉首尾空白。
String normalizeInline(String input) {
  final buffer = StringBuffer();
  var pendingSpace = false;
  for (final rune in input.runes) {
    if (_isSpace(rune)) {
      pendingSpace = buffer.isNotEmpty;
      continue;
    }
    if (pendingSpace) {
      buffer.write(' ');
      pendingSpace = false;
    }
    buffer.writeCharCode(rune);
  }
  return buffer.toString();
}

/// 去掉行首的缩进前缀（全角空格、半角空格、制表符）。
String stripIndent(String line) {
  var start = 0;
  while (start < line.length) {
    final char = line.codeUnitAt(start);
    if (char == 0x3000 || char == 0x20 || char == 0x09) {
      start++;
      continue;
    }
    break;
  }
  return line.substring(start);
}

/// 段落文本：去缩进 + 折叠空白。
String normalizeParagraph(String line) => normalizeInline(stripIndent(line));

/// 是否是空行（只有空白字符）。
bool isBlankLine(String line) =>
    line.trim().isEmpty || line.replaceAll(kIndentUnit, '').trim().isEmpty;

bool _isSpace(int rune) =>
    rune == 0x20 ||
    rune == 0x09 ||
    rune == 0x0A ||
    rune == 0x0D ||
    rune == 0x0C ||
    rune == 0x0B ||
    rune == 0x85 ||
    rune == 0xA0 ||
    rune == 0x3000;
