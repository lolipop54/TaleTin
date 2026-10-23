import 'package:flutter/services.dart';

import '../../domain/services/document_platform.dart';

/// Android 保留请求直到界面确认，避免冷启动准备期间丢失外部打开。
class ExternalBookRequest {
  const ExternalBookRequest(this.id, this.document);
  final int id;
  final PickedDocument document;
}

class ExternalBookOpenChannel {
  static const channel = MethodChannel('gtreader/external_book_open');

  void listen(void Function() onChanged) {
    channel.setMethodCallHandler((call) async {
      if (call.method == 'changed') onChanged();
    });
  }

  void dispose() => channel.setMethodCallHandler(null);

  Future<ExternalBookRequest?> next() async {
    Map<String, Object?>? value;
    try {
      value = await channel.invokeMapMethod<String, Object?>('next');
    } on MissingPluginException {
      // 无 Android 宿主的平台及组件测试没有外部打开入口。
      return null;
    }
    if (value == null || value['loading'] == true) return null;
    return ExternalBookRequest(
      value['id']! as int,
      PickedDocument(
        uri: value['uri']! as String,
        name: value['name']! as String,
        sizeBytes: value['sizeBytes'] as int?,
      ),
    );
  }

  /// 后来的请求替换了本请求时返回 false，旧导入不得再抢占当前画面。
  Future<bool> complete(int id) async =>
      await channel.invokeMethod<bool>('complete', {'id': id}) ?? false;
}
