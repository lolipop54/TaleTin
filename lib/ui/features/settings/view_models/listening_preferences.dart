import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/di/app_providers.dart';
import '../../../../domain/models/tts_settings.dart';

/// 首页只读取已保存的音色和语速。第三方 TTS 可能无法绑定，不能让它
/// 挡住应用首帧；连接和音色检测在页面显示后单独进行。
final listeningPreferencesProvider = StreamProvider<TtsSettings>(
  (ref) => ref.watch(ttsSettingsRepositoryProvider).watch(),
);
