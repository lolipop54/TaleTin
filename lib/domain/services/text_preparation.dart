/// TXT 正文准备契约：编码识别、UTF-8 转码与编码预览。
///
/// 具体实现放在引擎层的 TXT 适配器里，导入流水线与界面只依赖本契约，
/// 不直接接触解码细节。
library;

import 'dart:typed_data';

/// 编码识别结果。
class DetectedEncoding {
  const DetectedEncoding({required this.charset, required this.confident});

  /// 字符集名（UTF-8 / UTF-16LE / UTF-16BE / GB18030 ...）
  final String charset;

  /// 是否高置信（命中 BOM 或整体通过严格 UTF-8 校验）
  final bool confident;
}

abstract class TextPreparationService {
  /// 只看文件头识别编码，用于自动选择与界面提示。
  DetectedEncoding detectEncoding(Uint8List header);

  /// 把源文件转成 UTF-8 文本文件，返回实际使用的编码名。
  ///
  /// [overrideCharset] 是用户在编码预览里手动选择的编码。
  Future<String> prepareToUtf8({
    required String sourcePath,
    required String targetPath,
    required Uint8List header,
    String? overrideCharset,
  });

  /// 解码一段字节用于预览。
  Future<String> preview({required Uint8List bytes, required String charset});

  /// 手动切换编码时可选用的字符集列表。
  Future<List<String>> supportedCharsets();
}
