/// [TextPreparationService] 的实现：编码识别 + Rust 文本解码。
library;

import 'dart:typed_data';
import 'dart:isolate';
import 'dart:io';

import 'package:direct_read_rust/direct_read_rust.dart';

import '../../domain/services/document_platform.dart';
import '../../domain/services/text_preparation.dart';
import 'txt/encoding_detector.dart' as detector;

class TxtTextPreparation implements TextPreparationService {
  TxtTextPreparation({required DocumentPlatform platform});

  @override
  DetectedEncoding detectEncoding(Uint8List header) {
    final guess = detector.detectEncoding(header);
    return DetectedEncoding(charset: guess.charset, confident: guess.confident);
  }

  @override
  Future<String> prepareToUtf8({
    required String sourcePath,
    required String targetPath,
    required Uint8List header,
    String? overrideCharset,
  }) async {
    final charset = overrideCharset ?? detector.detectEncoding(header).charset;
    // 旧 JSON 修复仍需临时 UTF-8；全部解码在独立后台执行。
    await Isolate.run(() async {
      await File(targetPath).parent.create(recursive: true);
      await transcodeNativeFile(sourcePath, targetPath, charset);
    });
    return charset;
  }

  @override
  Future<String> preview({required Uint8List bytes, required String charset}) =>
      Future.value(
        decodeNativeText(bytes, charset, stripBom: charset.startsWith('UTF-')),
      );

  @override
  Future<List<String>> supportedCharsets() async => nativeCharsets;
}
