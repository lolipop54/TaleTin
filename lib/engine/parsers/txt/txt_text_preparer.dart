/// TXT 正文文本准备：把源文件转成 UTF-8 文本文件。
///
/// Dart 只原生解码 UTF-8 / UTF-16；GB18030 等中文常见编码交给平台 ICU
/// （设计文档 6.3）。转码后正文解析与编码无关，worker isolate 里只处理
/// UTF-8 文本，不依赖平台通道。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../../core/errors/import_error.dart';
import 'encoding_detector.dart';

/// 平台转码函数：把 [sourcePath] 按 [charsetName] 解码后写成 UTF-8 文件。
typedef TranscodeToUtf8 = Future<String> Function({
  required String sourcePath,
  required String charsetName,
  required String targetPath,
});

/// 平台解码函数：解码一段字节（编码预览用）。
typedef DecodeBytes = Future<String> Function(Uint8List bytes, String charset);

class TxtTextPreparer {
  const TxtTextPreparer({required this.transcode, required this.decodeBytes});

  final TranscodeToUtf8 transcode;
  final DecodeBytes decodeBytes;

  /// 把源文件转成 UTF-8 文本，返回实际使用的编码名。
  ///
  /// [overrideCharset] 是用户在「编码预览」里手动指定的编码。
  Future<String> prepare({
    required String sourcePath,
    required String targetPath,
    required EncodingGuess guess,
    String? overrideCharset,
  }) async {
    final charset = overrideCharset ?? guess.charset;
    if (charset == 'UTF-8') {
      await _copyAsUtf8(sourcePath: sourcePath, targetPath: targetPath);
      return charset;
    }
    if (charset == 'UTF-16LE' || charset == 'UTF-16BE') {
      await _decodeUtf16(
        sourcePath: sourcePath,
        targetPath: targetPath,
        littleEndian: charset == 'UTF-16LE',
      );
      return charset;
    }
    return transcode(
      sourcePath: sourcePath,
      charsetName: charset,
      targetPath: targetPath,
    );
  }

  /// 编码预览：解码一段字节，用于导入前确认编码是否正确。
  Future<String> preview({
    required Uint8List bytes,
    required String charset,
    String? overrideCharset,
  }) async {
    final name = overrideCharset ?? charset;
    if (name == 'UTF-8') {
      return const Utf8Decoder(allowMalformed: true).convert(bytes);
    }
    if (name == 'UTF-16LE' || name == 'UTF-16BE') {
      return _decodeUtf16Bytes(bytes, littleEndian: name == 'UTF-16LE');
    }
    // 平台解码：预览片段可能在多字节字符中间截断，平台按替换字符处理
    return decodeBytes(bytes, name);
  }

  /// UTF-8：去掉 BOM 后原样复制，不需要解码再编码。
  static Future<void> _copyAsUtf8({
    required String sourcePath,
    required String targetPath,
  }) async {
    final target = File(targetPath);
    await target.parent.create(recursive: true);
    final sink = target.openWrite();
    var first = true;
    try {
      await for (final chunk in File(sourcePath).openRead()) {
        var bytes = chunk;
        if (first) {
          first = false;
          if (bytes.length >= 3 &&
              bytes[0] == 0xEF &&
              bytes[1] == 0xBB &&
              bytes[2] == 0xBF) {
            bytes = Uint8List.fromList(bytes.sublist(3));
          }
        }
        sink.add(bytes);
      }
    } finally {
      await sink.flush();
      await sink.close();
    }
  }

  /// UTF-16 流式解码成 UTF-8，跨块保留半个码元。
  static Future<void> _decodeUtf16({
    required String sourcePath,
    required String targetPath,
    required bool littleEndian,
  }) async {
    final target = File(targetPath);
    await target.parent.create(recursive: true);
    final sink = target.openWrite();
    var carry = -1;
    var first = true;
    try {
      await for (final chunk in File(sourcePath).openRead()) {
        var bytes = chunk;
        if (first) {
          first = false;
          // 跳过 BOM
          if (bytes.length >= 2 &&
              ((littleEndian && bytes[0] == 0xFF && bytes[1] == 0xFE) ||
                  (!littleEndian && bytes[0] == 0xFE && bytes[1] == 0xFF))) {
            bytes = Uint8List.fromList(bytes.sublist(2));
          }
        }
        var index = 0;
        final codes = <int>[];
        if (carry >= 0) {
          if (bytes.isEmpty) continue;
          codes.add(littleEndian
              ? carry | (bytes[0] << 8)
              : (carry << 8) | bytes[0]);
          index = 1;
          carry = -1;
        }
        while (index + 1 < bytes.length) {
          codes.add(littleEndian
              ? bytes[index] | (bytes[index + 1] << 8)
              : (bytes[index] << 8) | bytes[index + 1]);
          index += 2;
        }
        if (index < bytes.length) carry = bytes[index];
        if (codes.isNotEmpty) {
          sink.add(utf8.encode(String.fromCharCodes(_combineSurrogates(codes))));
        }
      }
    } finally {
      await sink.flush();
      await sink.close();
    }
  }

  static String _decodeUtf16Bytes(Uint8List bytes, {required bool littleEndian}) {
    var start = 0;
    if (bytes.length >= 2 &&
        ((littleEndian && bytes[0] == 0xFF && bytes[1] == 0xFE) ||
            (!littleEndian && bytes[0] == 0xFE && bytes[1] == 0xFF))) {
      start = 2;
    }
    final codes = <int>[];
    for (var i = start; i + 1 < bytes.length; i += 2) {
      codes.add(littleEndian
          ? bytes[i] | (bytes[i + 1] << 8)
          : (bytes[i] << 8) | bytes[i + 1]);
    }
    if (codes.isEmpty) throw const ImportFailure(ImportErrorCode.decodeFailed);
    return String.fromCharCodes(_combineSurrogates(codes));
  }

  /// 代理对在解码时会被 String.fromCharCodes 自动合并，
  /// 但跨块截断的孤立代理需要兜底成替换字符，避免抛异常。
  static List<int> _combineSurrogates(List<int> codes) {
    final result = <int>[];
    for (var i = 0; i < codes.length; i++) {
      final code = codes[i];
      if (code >= 0xD800 && code <= 0xDBFF) {
        if (i + 1 < codes.length &&
            codes[i + 1] >= 0xDC00 &&
            codes[i + 1] <= 0xDFFF) {
          result.add(0x10000 + ((code - 0xD800) << 10) + (codes[i + 1] - 0xDC00));
          i++;
        } else {
          result.add(0xFFFD);
        }
      } else if (code >= 0xDC00 && code <= 0xDFFF) {
        result.add(0xFFFD);
      } else {
        result.add(code);
      }
    }
    return result;
  }
}
