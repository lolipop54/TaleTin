/// [DocumentPlatform] 的 Android 实现，包装 Pigeon 生成的通道接口。
library;

import 'package:flutter/services.dart';

import '../../domain/services/document_platform.dart';
import 'document_host_api.g.dart' as pigeon;

class AndroidDocumentPlatform implements DocumentPlatform {
  AndroidDocumentPlatform({pigeon.DocumentHostApi? api})
      : _api = api ?? pigeon.DocumentHostApi();

  final pigeon.DocumentHostApi _api;

  /// 单次拉取的字节上限（设计文档 6.1：约 1 MiB 分块）。
  static const int chunkBytes = 1024 * 1024;

  @override
  Future<List<PickedDocument>> pickDocuments() async {
    final picked = await _api.pickDocuments();
    return [
      for (final dto in picked)
        PickedDocument(
          uri: dto.uri,
          name: dto.name,
          sizeBytes: dto.sizeBytes,
        ),
    ];
  }

  @override
  Future<DocumentSession> open(String uri) async {
    final dto = await _api.openDocument(uri);
    return DocumentSession(id: dto.id, sizeBytes: dto.sizeBytes);
  }

  @override
  Future<Uint8List?> readChunk(DocumentSession session, int maxBytes) =>
      _api.readDocumentChunk(session.id, maxBytes);

  @override
  Future<void> close(DocumentSession session) => _api.closeDocument(session.id);

  @override
  Future<String> decodeBytes(Uint8List bytes, String charsetName) async {
    try {
      return await _api.decodeBytes(bytes, charsetName);
    } on PlatformException catch (e) {
      throw ArgumentError(e.message ?? '不支持的字符集：$charsetName');
    }
  }

  @override
  Future<String> transcodeToUtf8({
    required String sourcePath,
    required String charsetName,
    required String targetPath,
  }) async {
    try {
      return await _api.transcodeToUtf8(sourcePath, charsetName, targetPath);
    } on PlatformException catch (e) {
      throw ArgumentError(e.message ?? '不支持的字符集：$charsetName');
    }
  }

  @override
  Future<int> availableBytes(String path) => _api.availableBytes(path);

  @override
  Future<List<String>> supportedCharsets() => _api.supportedCharsets();
}
