/// [TextPreparationService] 的实现：编码识别 + 文本转换 + 平台解码。
library;

import 'dart:typed_data';

import '../../domain/services/document_platform.dart';
import '../../domain/services/text_preparation.dart';
import 'txt/encoding_detector.dart' as detector;
import 'txt/txt_text_preparer.dart';

class TxtTextPreparation implements TextPreparationService {
  TxtTextPreparation({required DocumentPlatform platform})
      : _platform = platform,
        _preparer = TxtTextPreparer(
          transcode: ({
            required String sourcePath,
            required String charsetName,
            required String targetPath,
          }) =>
              platform.transcodeToUtf8(
            sourcePath: sourcePath,
            charsetName: charsetName,
            targetPath: targetPath,
          ),
          decodeBytes: (bytes, charset) => platform.decodeBytes(bytes, charset),
        );

  final DocumentPlatform _platform;
  final TxtTextPreparer _preparer;

  @override
  DetectedEncoding detectEncoding(Uint8List header) {
    final guess = detector.detectEncoding(header);
    return DetectedEncoding(
      charset: guess.charset,
      confident: guess.confident,
    );
  }

  @override
  Future<String> prepareToUtf8({
    required String sourcePath,
    required String targetPath,
    required Uint8List header,
    String? overrideCharset,
  }) {
    return _preparer.prepare(
      sourcePath: sourcePath,
      targetPath: targetPath,
      guess: detector.detectEncoding(header),
      overrideCharset: overrideCharset,
    );
  }

  @override
  Future<String> preview({required Uint8List bytes, required String charset}) =>
      _preparer.preview(bytes: bytes, charset: charset);

  @override
  Future<List<String>> supportedCharsets() => _platform.supportedCharsets();
}
