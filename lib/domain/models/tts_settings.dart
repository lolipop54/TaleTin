import 'tts_state.dart';

/// 全局听书偏好；不持久化播放状态或倒计时。
class TtsSettings {
  const TtsSettings({
    this.enginePackage,
    this.voiceId,
    this.locale,
    this.speed = 1,
  });
  final String? enginePackage;
  final String? voiceId;
  final String? locale;
  final double speed;

  factory TtsSettings.selected(OfflineVoice voice, double speed) => TtsSettings(
    enginePackage: voice.enginePackage,
    voiceId: voice.voiceId,
    locale: voice.locale,
    speed: speed,
  );

  Map<String, Object?> toJson() => {
    'schemaVersion': 1,
    'enginePackage': enginePackage,
    'voiceId': voiceId,
    'locale': locale,
    'speed': speed,
  };

  factory TtsSettings.fromJson(Map<String, Object?> json) {
    final speed = json['speed'];
    return TtsSettings(
      enginePackage: json['enginePackage'] as String?,
      voiceId: json['voiceId'] as String?,
      locale: json['locale'] as String?,
      speed: speed is num && speed.isFinite
          ? (speed.toDouble().clamp(0.5, 2.0) * 10).round() / 10
          : 1,
    );
  }
}
