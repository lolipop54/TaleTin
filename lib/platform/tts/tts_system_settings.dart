import 'package:flutter/services.dart';

/// 只负责打开系统页面；下载由用户在系统语音界面完成。
Future<bool> openTtsSystemSettings(String? engine, bool install) async =>
    await const MethodChannel('gtreader/tts_settings')
        .invokeMethod<bool>('open', {'engine': engine, 'install': install}) ??
    false;
