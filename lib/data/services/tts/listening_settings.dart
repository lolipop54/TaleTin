import 'dart:async';

import '../../../domain/models/tts_settings.dart';
import '../../../domain/models/tts_state.dart';
import '../../../domain/repositories/tts_settings_repository.dart';
import '../../../domain/services/tts_engine.dart';
import 'listening_audio_focus.dart';

/// 音色枚举、试听和设置应用的协作者。
///
/// 它只操作引擎与设置，不决定播放/暂停、不发布听书状态，也不持有任务版本。
class ListeningSettings {
  ListeningSettings(this.engine, this.repository, {this.audioFocus});
  final TtsEngine engine;
  final TtsSettingsRepository? repository;
  final ListeningAudioFocus? audioFocus;
  TtsSettings value = const TtsSettings();
  OfflineVoice? voice;
  List<OfflineVoice> voices = const [];

  Future<List<TtsEngineInfo>> listEngines() => engine.listEngines();

  /// 浏览其它引擎后恢复正文正在使用的配置，不能悄悄替换音色。
  Future<List<OfflineVoice>> detectVoices(String? enginePackage) async {
    try {
      final init = await engine.initialize(enginePackage: enginePackage);
      if (!init.ok) throw StateError(init.message ?? '引擎不可用');
      return await engine.listVoices();
    } finally {
      if (voice != null) await apply(value);
    }
  }

  ListeningVoicePreview beginPreview(
    String id, {
    Duration timeout = const Duration(seconds: 20),
  }) {
    final done = Completer<void>();
    final subscription = engine.events.listen((event) {
      if (event.id != id || done.isCompleted) return;
      if (event is TtsDoneEvent) done.complete();
      if (event is TtsFailedEvent || event is TtsStoppedEvent) {
        done.completeError(StateError('试听未完成，请重新检测音色'));
      }
    });
    final completed = done.future.timeout(timeout);
    unawaited(completed.catchError((Object _) {}));
    return ListeningVoicePreview._(subscription, done, completed);
  }

  void validatePreview(OfflineVoice selected) {
    if (selected.requiresNetwork || !selected.isInstalled) {
      throw StateError('请先安装离线语音数据');
    }
  }

  Future<void> startPreview(
    OfflineVoice selected,
    String id, {
    required bool Function() canSpeak,
  }) async {
    validatePreview(selected);
    final init = await engine.initialize(enginePackage: selected.enginePackage);
    if (!init.ok ||
        !await engine.setVoice(selected.voiceId, locale: selected.locale)) {
      throw StateError('音色不可用');
    }
    await engine.setRate(value.speed);
    await audioFocus?.acquire();
    if (canSpeak()) await engine.speak(id, '这是离线听书试听，请确认声音是否清晰。');
  }

  Future<void> finishPreview() async {
    await engine.stop();
    await audioFocus?.release();
    if (voice != null) await apply(value);
  }

  Future<void> prepare() async {
    value = await repository?.load() ?? value;
    voice = await apply(value);
    await repository?.save(TtsSettings.selected(voice!, value.speed));
    value = TtsSettings.selected(voice!, value.speed);
  }

  Future<void> change({OfflineVoice? selected, double? rate}) async {
    if (voice == null) value = await repository?.load() ?? value;
    final previous = value;
    final requested = selected == null
        ? TtsSettings(
            enginePackage: value.enginePackage,
            voiceId: value.voiceId,
            locale: value.locale,
            speed: rate ?? value.speed,
          )
        : TtsSettings.selected(selected, rate ?? value.speed);
    try {
      final actual = await apply(requested);
      final next = TtsSettings.selected(actual, requested.speed);
      await repository?.save(next);
      value = next;
      voice = actual;
    } catch (error) {
      // 平台切换与落库任一步失败，回滚引擎；旧偏好仅在全部成功后替换。
      if (voice != null) {
        try {
          voice = await apply(previous);
        } catch (rollback) {
          voice = null;
          throw StateError('设置失败：$error；原音色恢复失败：$rollback');
        }
      }
      rethrow;
    }
  }

  Future<OfflineVoice> apply(TtsSettings requested) async {
    final init = await engine.initialize(
      enginePackage: requested.enginePackage,
    );
    if (!init.ok) throw StateError(init.message ?? '语音引擎初始化失败');
    voices = List.unmodifiable(await engine.listVoices());
    final selected = voices
        .where(
          (v) =>
              !v.requiresNetwork &&
              v.isInstalled &&
              (requested.voiceId == null
                  ? v.locale.toLowerCase().startsWith('zh')
                  : v.voiceId == requested.voiceId &&
                        v.enginePackage == requested.enginePackage &&
                        v.locale == requested.locale),
        )
        .firstOrNull;
    if (selected == null) {
      throw StateError(
        requested.voiceId == null
            ? '没有已安装的离线中文音色，请在系统语音设置安装后重新检测'
            : '已保存的离线音色不可用，请重新选择或安装语音数据',
      );
    }
    if (!await engine.setVoice(selected.voiceId, locale: selected.locale)) {
      throw StateError('音色不可用');
    }
    await engine.setRate(requested.speed);
    return selected;
  }
}

/// 一次试听的临时事件监听；主播放事件仍只由 ListeningController 消费。
class ListeningVoicePreview {
  ListeningVoicePreview._(this._subscription, this._done, this.completed);

  final StreamSubscription<TtsEngineEvent> _subscription;
  final Completer<void> _done;
  final Future<void> completed;

  Future<void> close() async {
    await _subscription.cancel();
    if (!_done.isCompleted) _done.complete();
  }
}
