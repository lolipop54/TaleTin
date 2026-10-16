import '../models/tts_settings.dart';

abstract class TtsSettingsRepository {
  Future<TtsSettings> load();

  /// 只观察已保存的偏好，不连接系统语音引擎。
  Stream<TtsSettings> watch();
  Future<void> save(TtsSettings settings);
}
