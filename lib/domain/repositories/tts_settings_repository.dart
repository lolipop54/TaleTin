import '../models/tts_settings.dart';

abstract class TtsSettingsRepository {
  Future<TtsSettings> load();
  Future<void> save(TtsSettings settings);
}
