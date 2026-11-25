import 'dart:async';

import 'package:flutter/services.dart';

import '../../core/diagnostics/app_errors.dart';
import '../../data/services/tts/listening_audio_handler.dart';
import '../../domain/models/tts_state.dart';
import '../../domain/services/listening_deadline.dart';
import '../../domain/services/tts_engine.dart';

/// Windows 只负责声音和系统媒体控件。书籍、阅读位置和队列由共用控制器持有。
class WindowsListeningEngine
    implements TtsEngine, PreparedTtsEngine, ListeningDeadline {
  WindowsListeningEngine(this.handler) {
    _channel.setMethodCallHandler(_receive);
  }

  static const _channel = MethodChannel('taletin/windows_listening');
  static const _engine = 'windows.system.speech';
  final ListeningAudioHandler handler;
  final _events = StreamController<TtsEngineEvent>.broadcast();
  final _deadlines = StreamController<int>.broadcast();
  StreamSubscription<ListeningState>? _media;
  (String, String, String)? _published;

  void bindMedia() {
    _media = handler.service!.state.listen((state) {
      final active =
          state.hasSession &&
          !state.previewing &&
          state.status != TtsStatus.error;
      final status = !active
          ? 'closed'
          : state.desiredPlaying
          ? 'playing'
          : 'paused';
      final next = (
        status,
        active ? state.bookTitle : '',
        active ? state.chapterTitle : '',
      );
      if (next == _published) return;
      _published = next;
      unawaited(
        _channel
            .invokeMethod<void>('media', [next.$1, next.$2, next.$3])
            .catchError((Object error, StackTrace stack) {
              if (_published == next) _published = null;
              AppErrors.report(error, stack, operation: '更新系统听书控件失败');
            }),
      );
    });
  }

  Future<void> _receive(MethodCall call) async {
    final args = call.arguments as List;
    switch (call.method) {
      case 'started':
        _events.add(TtsStartedEvent(args.first as String));
      case 'range':
        _events.add(
          TtsRangeEvent(args[0] as String, args[1] as int, args[2] as int),
        );
      case 'done':
        _events.add(TtsDoneEvent(args.first as String));
      case 'error':
        _events.add(
          TtsFailedEvent(
            args[0] as String,
            TtsFailureCode.values.byName(args[1] as String),
            args[2] as String,
          ),
        );
      case 'deadline':
        _deadlines.add(args.first as int);
      case 'command':
        switch (args.first) {
          case 'play':
            await handler.play();
          case 'pause':
            await handler.pause();
          case 'stop':
            await handler.stop();
          case 'next':
            await handler.skipToNext();
          case 'previous':
            await handler.skipToPrevious();
          case 'hold':
            await handler.holdForInterruption();
          case 'resumeHeld':
            await handler.resumeAfterInterruption();
        }
    }
  }

  @override
  Stream<TtsEngineEvent> get events => _events.stream;
  @override
  Stream<int> get expired => _deadlines.stream;
  @override
  Future<int> now() async => (await _channel.invokeMethod<int>('now'))!;
  @override
  Future<void> arm(int version, int? deadlineMs) =>
      _channel.invokeMethod<void>('arm', [version, deadlineMs]);
  @override
  Future<List<TtsEngineInfo>> listEngines() async => [
    const TtsEngineInfo(
      packageName: _engine,
      label: 'Windows 系统语音',
      isDefault: true,
    ),
  ];
  @override
  Future<TtsInitOutcome> initialize({String? enginePackage}) async {
    if (enginePackage != null && enginePackage != _engine) {
      return const TtsInitOutcome(
        ok: false,
        enginePackage: _engine,
        message: '此语音引擎在当前电脑上不可用',
      );
    }
    await _channel.invokeMethod<void>('initialize');
    return const TtsInitOutcome(ok: true, enginePackage: _engine);
  }

  @override
  Future<void> cancelInitialization() async {}
  @override
  Future<List<OfflineVoice>> listVoices() async {
    final voices = await _channel.invokeListMethod<List>('voices') ?? [];
    return [
      for (final voice in voices)
        OfflineVoice(
          enginePackage: _engine,
          voiceId: voice[0] as String,
          displayName: voice[1] as String,
          locale: voice[2] as String,
          requiresNetwork: false,
          isInstalled: true,
        ),
    ];
  }

  @override
  Future<bool> setVoice(String voiceId, {String? locale}) async =>
      await _channel.invokeMethod<bool>('voice', [voiceId, locale]) ?? false;
  @override
  Future<void> setRate(double rate) =>
      _channel.invokeMethod<void>('rate', [rate]);
  @override
  Future<void> speak(String id, String text) =>
      _channel.invokeMethod<void>('speak', [id, text]);
  @override
  Future<void> prepareSpeech(String text) =>
      _channel.invokeMethod<void>('prepare', [text]);
  @override
  Future<void> stop() => _channel.invokeMethod<void>('stop');
  @override
  Future<void> holdSpeech() => _channel.invokeMethod<void>('hold');
  @override
  Future<void> resumeSpeech() => _channel.invokeMethod<void>('resume');
  @override
  Future<int> maxSpeechInputLength() async => 4096;
  @override
  Future<bool> isLanguageAvailable(String locale) async => (await listVoices())
      .any((voice) => voice.locale.toLowerCase() == locale.toLowerCase());
  @override
  Future<void> dispose() async {
    await _media?.cancel();
    try {
      await _channel.invokeMethod<void>('shutdown');
    } finally {
      _channel.setMethodCallHandler(null);
      await _events.close();
      await _deadlines.close();
    }
  }
}
