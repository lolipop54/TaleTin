import '../../../domain/models/tts_state.dart';
import '../../../domain/services/tts_engine.dart';
import '../../../platform/tts/native_tts_channel.dart';

/// 平台 DTO 只在这里转换，播放控制器不依赖 Pigeon。
class NativeTtsEngine implements TtsEngine, PreparedTtsEngine {
  NativeTtsEngine(this.channel);

  final NativeTtsChannel channel;
  String _package = '';

  @override
  Stream<TtsEngineEvent> get events => channel.events.map((event) {
    final id = event.utteranceId;
    return switch (event) {
      TtsStarted() => TtsStartedEvent(id),
      TtsDone() => TtsDoneEvent(id),
      TtsRangeStart() => TtsRangeEvent(id, event.start, event.end),
      TtsStopped() => TtsStoppedEvent(id, event.interrupted),
      TtsErrorEvent() => TtsFailedEvent(
        id,
        event.code == TtsErrorCode.init
            ? TtsFailureCode.initialize
            : TtsFailureCode.values.byName(event.code.name),
        event.message,
      ),
    };
  });

  @override
  Future<TtsInitOutcome> initialize({String? enginePackage}) async {
    final result = await channel.initialize(enginePackage);
    _package = result.enginePackage;
    return TtsInitOutcome(
      ok: result.ok,
      enginePackage: _package,
      message: result.message,
    );
  }

  @override
  Future<List<TtsEngineInfo>> listEngines() async => [
    for (final engine in await channel.listEngines())
      TtsEngineInfo(
        packageName: engine.packageName,
        label: engine.label,
        isDefault: engine.isDefault,
      ),
  ];

  @override
  Future<List<OfflineVoice>> listVoices() async => [
    for (final voice in await channel.listVoices())
      OfflineVoice(
        enginePackage: _package,
        voiceId: voice.name,
        displayName: voice.name,
        locale: voice.locale,
        requiresNetwork: voice.isNetworkRequired,
        isInstalled: !voice.features.contains('notInstalled'),
        verification:
            voice.isNetworkRequired || voice.features.contains('notInstalled')
            ? VoiceVerification.unavailable
            : VoiceVerification.candidate,
      ),
  ];

  @override
  Future<bool> setVoice(String voiceId, {String? locale}) =>
      channel.setVoice(voiceId, locale: locale);
  @override
  Future<void> setRate(double rate) => channel.setRate(rate);
  @override
  Future<void> speak(String id, String text) => channel.speak(id, text);
  @override
  Future<void> prepareSpeech(String text) => channel.prepareSpeech(text);
  @override
  Future<void> stop() => channel.stop();
  @override
  Future<int> maxSpeechInputLength() => channel.maxSpeechInputLength();
  @override
  Future<bool> isLanguageAvailable(String locale) =>
      channel.isLanguageAvailable(locale);
  @override
  Future<void> dispose() async {
    await channel.shutdown();
    await channel.dispose();
  }
}
