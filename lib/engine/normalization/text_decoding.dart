/// 文本字节解码：EPUB 内部文档（OPF / NCX / XHTML）用。
///
/// 规范要求 UTF-8 或 UTF-16，实际样本里绝大多数是 UTF-8（可带 BOM）。
/// 这里按 BOM 判定，其次严格 UTF-8，最后按容错 UTF-8 兜底，
/// 不引入平台依赖，worker isolate 里也能用。
library;

import 'dart:convert';
import 'dart:typed_data';

/// 解码文本字节，自动去掉 BOM。
String decodeTextBytes(Uint8List bytes) {
  if (bytes.length >= 2) {
    if (bytes[0] == 0xFF && bytes[1] == 0xFE) {
      return _utf16(bytes, 2, littleEndian: true);
    }
    if (bytes[0] == 0xFE && bytes[1] == 0xFF) {
      return _utf16(bytes, 2, littleEndian: false);
    }
  }
  var start = 0;
  if (bytes.length >= 3 &&
      bytes[0] == 0xEF &&
      bytes[1] == 0xBB &&
      bytes[2] == 0xBF) {
    start = 3;
  }
  final body = start == 0 ? bytes : Uint8List.sublistView(bytes, start);
  return const Utf8Decoder(allowMalformed: true).convert(body);
}

/// UTF-16 解码（含代理对合并与孤立代理兜底）。
String _utf16(Uint8List bytes, int start, {required bool littleEndian}) {
  final codes = <int>[];
  for (var i = start; i + 1 < bytes.length; i += 2) {
    codes.add(littleEndian
        ? bytes[i] | (bytes[i + 1] << 8)
        : (bytes[i] << 8) | bytes[i + 1]);
  }
  return String.fromCharCodes(codes);
}
