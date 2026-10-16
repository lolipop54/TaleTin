import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/di/app_providers.dart';
import '../../../../domain/models/tts_state.dart';
import '../../../../domain/services/tts_engine.dart';
import 'listening_panel_view_model.dart';

class VoiceChoices {
  const VoiceChoices(
    this.engines,
    this.voices,
    this.engine, {
    this.busy = false,
    this.loadingVoices = false,
    this.message,
    this.error,
  });
  final List<TtsEngineInfo> engines;
  final List<OfflineVoice> voices;
  final String? engine;
  final bool busy;
  final bool loadingVoices;
  final String? message;
  // 简洁设置页只显示失败信息，阅读中的试听弹层仍可显示操作提示。
  final String? error;
}

final listeningVoiceChoicesProvider =
    AsyncNotifierProvider.autoDispose<ListeningVoiceChoices, VoiceChoices>(
      ListeningVoiceChoices.new,
    );

class ListeningVoiceChoices extends AsyncNotifier<VoiceChoices> {
  int _detection = 0;

  @override
  Future<VoiceChoices> build() async {
    final service = ref.watch(listeningServiceProvider);
    final detection = ++_detection;
    ref.onDispose(() => _detection++);
    // 读取一次保存值；后续点选音色时落库，不能因此重建当前检测/试听页面。
    final preferences = await ref.read(ttsSettingsRepositoryProvider).load();
    final engines = await service.listEngines();
    final initial = VoiceChoices(
      engines,
      const [],
      service.snapshot.voice?.enginePackage ??
          preferences.enginePackage ??
          engines.where((e) => e.isDefault).firstOrNull?.packageName,
      loadingVoices: true,
    );
    final connection = service.prepareVoices().then(
      (voices) => VoiceChoices(
        engines,
        voices,
        service.snapshot.voice?.enginePackage ?? initial.engine,
        error: service.snapshot.error,
      ),
    );
    try {
      return await connection.timeout(kTtsPageConnectionWait);
    } on TimeoutException {
      // 一秒只决定页面何时打开，不取消连接，也不提前报告初始化失败。
      unawaited(_finishConnection(connection, initial, detection));
      return initial;
    }
  }

  Future<void> _finishConnection(
    Future<VoiceChoices> connection,
    VoiceChoices initial,
    int detection,
  ) async {
    try {
      final result = await connection;
      if (ref.mounted && detection == _detection) state = AsyncData(result);
    } catch (error) {
      if (!ref.mounted || detection != _detection) return;
      state = AsyncData(
        VoiceChoices(
          initial.engines,
          const [],
          initial.engine,
          error: '$error',
        ),
      );
    }
  }

  Future<void> _run(Future<VoiceChoices> Function(VoiceChoices) action) async {
    final previous = state.value;
    if (previous == null || previous.busy) return;
    ++_detection;
    state = AsyncData(
      VoiceChoices(
        previous.engines,
        previous.voices,
        previous.engine,
        busy: true,
      ),
    );
    try {
      final next = await action(previous);
      if (ref.mounted) state = AsyncData(next);
    } catch (error) {
      if (ref.mounted) {
        state = AsyncData(
          VoiceChoices(
            previous.engines,
            previous.voices,
            previous.engine,
            message: '$error',
            error: '$error',
          ),
        );
      }
    }
  }

  Future<void> detect(String? engine) async {
    final old = state.value;
    if (old == null || old.busy) return;
    ++_detection;
    state = AsyncData(
      VoiceChoices(
        old.engines,
        const [],
        engine,
        busy: true,
        loadingVoices: true,
      ),
    );
    final service = ref.read(listeningServiceProvider);
    try {
      final voices = await service.detectVoices(engine);
      final engines = await service.listEngines();
      if (ref.mounted) state = AsyncData(VoiceChoices(engines, voices, engine));
    } catch (error) {
      if (ref.mounted) {
        state = AsyncData(
          VoiceChoices(old.engines, old.voices, old.engine, error: '$error'),
        );
      }
    }
  }

  Future<void> choose(OfflineVoice voice) => _run((old) async {
    final service = ref.read(listeningServiceProvider);
    final ok = await service.setVoice(voice);
    return VoiceChoices(
      old.engines,
      old.voices,
      old.engine,
      message: ok
          ? '已选择 ${voice.displayName} · ${voice.locale}'
          : service.snapshot.error,
      error: ok ? null : service.snapshot.error,
    );
  });

  Future<void> preview(OfflineVoice voice) => _run((old) async {
    await ref.read(listeningServiceProvider).previewVoice(voice);
    return VoiceChoices(
      old.engines,
      old.voices,
      old.engine,
      message: '试听完成。请在断网后试听，确认本机离线可用。',
    );
  });

  Future<void> openSettings(bool install) => _run((old) async {
    final open = ref.read(ttsSystemSettingsProvider);
    await ref.read(listeningServiceProvider).pause();
    final opened = await open(old.engine, install);
    return VoiceChoices(
      old.engines,
      old.voices,
      old.engine,
      message: opened ? '返回后可重新检测' : '系统未提供此页面，请在系统设置中安装语音数据',
      error: opened ? null : '系统未提供语音设置页面',
    );
  });
}
