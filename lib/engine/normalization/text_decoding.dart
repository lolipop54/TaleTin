/// 文本字节解码：EPUB 内部文档（OPF / NCX / XHTML）用。
///
/// 规范要求 UTF-8 或 UTF-16，实际样本里绝大多数是 UTF-8（可带 BOM）。
/// 按 BOM 选择字节序，其余按容错 UTF-8；由 Rust 解码，
/// 不经过 Android 消息通道，worker isolate 里也能用。
library;

import 'dart:typed_data';

import 'package:direct_read_rust/direct_read_rust.dart';

/// 解码文本字节，自动去掉 BOM。
String decodeTextBytes(Uint8List bytes) {
  if (bytes.length >= 2) {
    if (bytes[0] == 0xFF && bytes[1] == 0xFE) {
      return decodeNativeText(bytes, 'UTF-16LE', stripBom: true);
    }
    if (bytes[0] == 0xFE && bytes[1] == 0xFF) {
      return decodeNativeText(bytes, 'UTF-16BE', stripBom: true);
    }
  }
  return decodeNativeText(bytes, 'UTF-8', stripBom: true);
}
