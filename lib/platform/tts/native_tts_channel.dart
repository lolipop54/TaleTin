/// 原生 TTS 通道的 Dart 包装（离线听书实现计划 第 5 节）。
///
/// 这一层只做两件事：转发宿主方法、把原生回调按 ID 分派成事件流。
/// 它不保存播放状态、不决定读哪一句——那是 B1 之后的听书控制器的事。
library;

import 'dart:async';

import 'package:flutter/services.dart';

import '../channels/tts_api.g.dart';

export '../channels/tts_api.g.dart'
    show TtsEngineDto, TtsErrorCode, TtsInitResultDto, TtsVoiceDto;

/// 原生上报的一个事件。全部带 `utteranceId`，接收方据此判断是否属于当前会话，
/// 不能拿「现在正在读的那句」去顶替（实现计划 第 5、7 节）。
sealed class TtsEvent {
  const TtsEvent(this.utteranceId);

  final String utteranceId;
}

/// 确认开始发声。
class TtsStarted extends TtsEvent {
  const TtsStarted(super.utteranceId);
}

/// 正在朗读原文 [start, end)（相对本次发送的文本，UTF-16 偏移）。
class TtsRangeStart extends TtsEvent {
  const TtsRangeStart(super.utteranceId, this.start, this.end);

  final int start;
  final int end;
}

/// 整段读完。
class TtsDone extends TtsEvent {
  const TtsDone(super.utteranceId);
}

/// 被停止；[interrupted] 为 true 表示不是我们主动停的（引擎/系统打断）。
class TtsStopped extends TtsEvent {
  const TtsStopped(super.utteranceId, this.interrupted);

  final bool interrupted;
}

/// 出错。[message] 是原生原始信息，只用于排查；界面提示按 [code] 生成中文文案。
class TtsErrorEvent extends TtsEvent {
  const TtsErrorEvent(super.utteranceId, this.code, this.message);

  final TtsErrorCode code;
  final String message;
}

/// 把 [TtsEventsFlutterApi] 的原生回调转成 [Stream]。
///
/// 原生侧在主线程回调，Dart 侧收到事件后按顺序放进同一个 Stream，
/// 让使用方用一个 `listen` 串行消费（实现计划 第 7 节）。
class NativeTtsChannel {
  NativeTtsChannel({TtsHostApi? hostApi}) : _hostApi = hostApi ?? TtsHostApi() {
    TtsEventsFlutterApi.setUp(_EventBridge(_events.add, _deadlines.add));
  }

  final TtsHostApi _hostApi;
  final _deadlines = StreamController<int>.broadcast();
  Stream<int> get deadlines => _deadlines.stream;
  Future<int> elapsedRealtime() => _hostApi.elapsedRealtime();
  Future<void> setSleepDeadline(int version, int? deadlineMs) =>
      _hostApi.setSleepDeadline(version, deadlineMs);
  final StreamController<TtsEvent> _events =
      StreamController<TtsEvent>.broadcast();

  /// 原生事件流（广播流，可多处监听）。
  Stream<TtsEvent> get events => _events.stream;

  Future<TtsInitResultDto> initialize(String? enginePackage) =>
      _hostApi.initialize(enginePackage);

  Future<void> cancelInitialization() => _hostApi.cancelInitialization();

  Future<List<TtsEngineDto>> listEngines() => _hostApi.listEngines();

  Future<List<TtsVoiceDto>> listVoices() => _hostApi.listVoices();

  Future<bool> setVoice(String voiceName, {String? locale}) =>
      _hostApi.setVoice(voiceName, locale);

  Future<void> setRate(double rate) => _hostApi.setRate(rate);

  /// 提交一段文本。返回只代表请求已被接收，是否开始发声看 [TtsStarted]。
  Future<void> speak(String utteranceId, String text) =>
      _hostApi.speak(utteranceId, text);

  Future<void> prepareSpeech(String text) =>
      const MethodChannel('gtreader/tts_prepare')
          .invokeMethod<void>('prepare', text);

  Future<void> stop() => _hostApi.stop();

  /// 提示音等短暂抢占期间按住发声；续播从同一帧继续。
  Future<void> holdSpeech() => _hostApi.holdSpeech();

  Future<void> resumeSpeech() => _hostApi.resumeSpeech();

  Future<void> shutdown() => _hostApi.shutdown();

  /// 引擎单次可接受的最大文本长度（UTF-16 单元）。
  Future<int> maxSpeechInputLength() => _hostApi.maxSpeechInputLength();

  Future<bool> isLanguageAvailable(String locale) =>
      _hostApi.isLanguageAvailable(locale);

  /// 关掉事件通道。只在应用级服务真正释放时调用，退出阅读页不调。
  Future<void> dispose() async {
    TtsEventsFlutterApi.setUp(null);
    await _events.close();
    await _deadlines.close();
  }
}

/// 把生成接口公布的回调翻译成 [TtsEvent]。
class _EventBridge implements TtsEventsFlutterApi {
  _EventBridge(this._emit, this._deadline);
  final void Function(int) _deadline;

  @override
  void onSleepDeadline(int version) => _deadline(version);

  final void Function(TtsEvent event) _emit;

  @override
  void onStarted(String utteranceId) => _emit(TtsStarted(utteranceId));

  @override
  void onRangeStart(String utteranceId, int start, int end) =>
      _emit(TtsRangeStart(utteranceId, start, end));

  @override
  void onDone(String utteranceId) => _emit(TtsDone(utteranceId));

  @override
  void onStopped(String utteranceId, bool interrupted) =>
      _emit(TtsStopped(utteranceId, interrupted));

  @override
  void onError(String utteranceId, TtsErrorCode code, String message) =>
      _emit(TtsErrorEvent(utteranceId, code, message));
}
