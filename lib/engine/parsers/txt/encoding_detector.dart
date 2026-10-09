/// TXT 编码识别（设计文档 6.3：UTF-8/BOM、UTF-16 LE/BE、GB18030 常见中文）。
///
/// 只根据文件头判定：BOM 优先，其次严格 UTF-8 校验，再次 UTF-16 无 BOM 的
/// 零字节分布启发，最后落到 GB18030。识别结果可以人工覆盖，
/// 所以这里宁可给出「不确定」标记，也不猜得过于激进。
library;

import 'dart:typed_data';

/// 编码识别结果。
class EncodingGuess {
  const EncodingGuess({
    required this.charset,
    required this.confident,
    this.bomLength = 0,
  });

  /// 用于平台转码的字符集名（`Charset.forName` 可识别的写法）
  final String charset;

  /// 是否高置信：命中 BOM 或整体通过严格 UTF-8 校验
  final bool confident;

  /// BOM 字节数，UTF-8 转码时需要跳过
  final int bomLength;

  /// UTF-8 或 UTF-16 都可以由 Dart 直接解码，无需平台 ICU。
  bool get isDartDecodable =>
      charset == 'UTF-8' || charset == 'UTF-16LE' || charset == 'UTF-16BE';
}

/// 中文常见编码的兜底值（GB18030 覆盖 GBK/GB2312 的字符范围）。
const String kFallbackCharset = 'GB18030';

/// 分析文件头，猜测编码。
EncodingGuess detectEncoding(Uint8List header) {
  // 1) BOM
  if (header.length >= 3 &&
      header[0] == 0xEF &&
      header[1] == 0xBB &&
      header[2] == 0xBF) {
    return const EncodingGuess(
        charset: 'UTF-8', confident: true, bomLength: 3);
  }
  if (header.length >= 2 && header[0] == 0xFF && header[1] == 0xFE) {
    return const EncodingGuess(
        charset: 'UTF-16LE', confident: true, bomLength: 2);
  }
  if (header.length >= 2 && header[0] == 0xFE && header[1] == 0xFF) {
    return const EncodingGuess(
        charset: 'UTF-16BE', confident: true, bomLength: 2);
  }

  // 2) 严格 UTF-8 校验（忽略末尾可能被截断的多字节序列）
  if (isValidUtf8(header)) {
    return const EncodingGuess(charset: 'UTF-8', confident: true);
  }

  // 3) 无 BOM 的 UTF-16：中文字符无零字节，ASCII 字符会留下零字节，
  //    按零字节的奇偶分布判断字节序。
  final utf16 = _guessUtf16WithoutBom(header);
  if (utf16 != null) {
    return EncodingGuess(charset: utf16, confident: false);
  }

  return const EncodingGuess(charset: kFallbackCharset, confident: false);
}

/// 严格 UTF-8 校验。
///
/// 允许末尾存在不完整的多字节序列（文件头是截断的）；[complete] 为 true 时
/// 要求整个输入严格合法（用于整文件校验）。
bool isValidUtf8(Uint8List bytes, {bool complete = false}) {
  var i = 0;
  while (i < bytes.length) {
    final b = bytes[i];
    int extra;
    int minSecond;
    if (b < 0x80) {
      i++;
      continue;
    } else if (b >= 0xC2 && b <= 0xDF) {
      extra = 1;
      minSecond = 0x80;
    } else if (b >= 0xE0 && b <= 0xEF) {
      extra = 2;
      minSecond = 0x80;
    } else if (b >= 0xF0 && b <= 0xF4) {
      extra = 3;
      minSecond = 0x80;
    } else {
      return false;
    }
    if (i + extra >= bytes.length) {
      // 末尾截断：只有在允许截断时才放行
      return !complete;
    }
    for (var k = 1; k <= extra; k++) {
      final c = bytes[i + k];
      final lower = k == 1 ? minSecond : 0x80;
      if (c < lower || c > 0xBF) return false;
    }
    i += extra + 1;
  }
  return true;
}

/// 无 BOM 的 UTF-16 猜测；证据不足时返回 null。
String? _guessUtf16WithoutBom(Uint8List bytes) {
  if (bytes.length < 32) return null;
  var evenZero = 0;
  var oddZero = 0;
  for (var i = 0; i < bytes.length; i++) {
    if (bytes[i] == 0) {
      if (i.isEven) {
        evenZero++;
      } else {
        oddZero++;
      }
    }
  }
  final zeros = evenZero + oddZero;
  // 纯 ASCII 的 UTF-8 文本没有零字节，中文 GBK 也很少出现零字节
  if (zeros * 10 < bytes.length * 2) return null;
  if (oddZero > evenZero * 4) return 'UTF-16LE';
  if (evenZero > oddZero * 4) return 'UTF-16BE';
  return null;
}
