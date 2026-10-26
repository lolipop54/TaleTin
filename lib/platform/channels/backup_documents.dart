import 'package:flutter/services.dart';

/// 用户主动选择的 SAF 文档；输入复用已有 AndroidDocumentPlatform 分块读取。
class BackupDocuments {
  static const _channel = MethodChannel('gtreader/backup_documents');

  Future<String?> pick() => _channel.invokeMethod<String>('pick');

  /// 打开系统相册，只请求用户选中的一张图片。
  Future<String?> pickImage() => _channel.invokeMethod<String>('pickImage');

  Future<List<String>> pickImages(int limit) async =>
      await _channel.invokeListMethod<String>('pickImages', {'limit': limit}) ??
      [];
  Future<String?> create(String name, String mime) =>
      _channel.invokeMethod<String>('create', {'name': name, 'mime': mime});
  Future<void> open(String uri) => _channel.invokeMethod('open', {'uri': uri});
  Future<void> write(Uint8List bytes) =>
      _channel.invokeMethod('write', {'bytes': bytes});
  Future<void> finish() => _channel.invokeMethod('finish');

  /// 返回 false 表示提供方没有删除残留文件，调用方必须明确提示。
  Future<bool> abort(String uri) async =>
      await _channel.invokeMethod<bool>('abort', {'uri': uri}) ?? false;
}
