/// 原生 TTS 引擎的领域契约（离线听书实现计划 第 5 节）。
///
/// 这里只有接口和纯 Dart 的数据类型，不引用 Flutter、Pigeon 和生成代码：
/// `platform/tts/native_tts_channel.dart` 的 DTO 与事件由
/// `data/services/tts/` 里的适配器翻译成本文件的类型。
library;

import '../models/tts_state.dart';

/// 可选能力：只提前合成一段；实际播出仍由控制器的 speak 请求决定。
abstract interface class PreparedTtsEngine {
  Future<void> prepareSpeech(String text);
}

/// 系统里可见的一个 TTS 引擎。
class TtsEngineInfo {
  const TtsEngineInfo({
    required this.packageName,
    required this.label,
    required this.isDefault,
  });

  /// 引擎包名，例如 com.google.android.tts
  final String packageName;

  /// 给用户看的名字；系统不给名字时退回包名
  final String label;

  /// 是否是系统当前默认引擎
  final bool isDefault;

  @override
  String toString() => 'TtsEngineInfo($packageName${isDefault ? '·默认' : ''})';
}

/// 引擎初始化结果。失败不是异常，由界面按 [message] 给出中文提示。
class TtsInitOutcome {
  const TtsInitOutcome({
    required this.ok,
    required this.enginePackage,
    this.message,
  });

  final bool ok;

  /// 实际生效的引擎包名（请求传 null 时是系统默认引擎）
  final String enginePackage;

  /// 失败原因（原生原始信息或已归类的说明），成功时为 null
  final String? message;

  @override
  String toString() => 'TtsInitOutcome(${ok ? 'ok' : 'fail'}·$enginePackage)';
}

/// 播放失败的原因分类，界面据此生成中文文案。
enum TtsFailureCode {
  /// 初始化失败（引擎不可用、语音数据缺失）
  initialize,

  /// 合成失败
  synthesis,

  /// 音频输出失败（没有可用输出设备）
  output,

  /// 网络相关错误；离线音色不应出现
  network,

  /// 网络超时
  networkTimeout,

  /// 引擎服务异常
  service,

  /// 引擎不支持这个语言或音色
  unsupportedLanguage,

  /// 指定引擎/音色未安装
  notInstalled,

  /// 入参不合法，或原生那边没有这段文本
  invalidRequest,

  /// 其他未归类错误
  other,
}

/// 引擎上报的事件。
///
/// **每个事件都带自己的 [id]**：接收方据此判断它是否属于当前会话，
/// 不能拿「现在正在读的那句」去顶替（实现计划第 5、7 节）。
sealed class TtsEngineEvent {
  const TtsEngineEvent(this.id);

  final String id;
}

/// 该段文本确认开始发声。
class TtsStartedEvent extends TtsEngineEvent {
  const TtsStartedEvent(super.id);
}

/// 正在朗读本次发送文本的 [start, end)（UTF-16 偏移，相对发送的文本）。
class TtsRangeEvent extends TtsEngineEvent {
  const TtsRangeEvent(super.id, this.start, this.end);

  final int start;
  final int end;
}

/// 整段读完。
class TtsDoneEvent extends TtsEngineEvent {
  const TtsDoneEvent(super.id);
}

/// 被停止。[interrupted] 为 true 表示不是我们主动停的（引擎或系统打断）。
class TtsStoppedEvent extends TtsEngineEvent {
  const TtsStoppedEvent(super.id, this.interrupted);

  final bool interrupted;
}

/// 出错。
class TtsFailedEvent extends TtsEngineEvent {
  const TtsFailedEvent(super.id, this.code, this.message);

  final TtsFailureCode code;

  /// 原始排查信息，不直接展示给用户
  final String message;
}

/// TTS 引擎。
///
/// 实现要挂在应用级服务上，不依赖 Activity：返回书架、Home、锁屏都要能继续读。
abstract class TtsEngine {
  /// 事件流（广播流）。
  ///
  /// 事件按到达顺序发出，使用方在同一个控制器里串行消费（实现计划第 7 节）。
  Stream<TtsEngineEvent> get events;

  /// 初始化（换引擎时重新初始化）。传 null 用系统默认引擎。
  Future<TtsInitOutcome> initialize({String? enginePackage});

  /// 系统里可见的引擎清单，始终包含系统默认引擎。
  Future<List<TtsEngineInfo>> listEngines();

  /// 当前引擎的音色清单，需要先 [initialize]。
  Future<List<OfflineVoice>> listVoices();

  /// 切换音色（同一引擎内）。音色不存在时返回 false，调用方保留原音色。
  Future<bool> setVoice(String voiceId, {String? locale});

  /// 设置语速倍率（相对引擎默认语速，不承诺时长精确成倍）。
  Future<void> setRate(double rate);

  /// 提交一段文本。返回只代表请求已受理，真的开始发声以 [TtsStartedEvent] 为准。
  Future<void> speak(String id, String text);

  /// 停止发声并丢弃未播内容。原生没有真正的暂停，暂停也走这里。
  Future<void> stop();

  /// 引擎单次可接受的最大文本长度（UTF-16 单元），用于长句拆分上限。
  Future<int> maxSpeechInputLength();

  /// 当前引擎是否支持该语言（BCP-47，例如 zh-CN）。
  Future<bool> isLanguageAvailable(String locale);

  /// 释放事件通道。只在应用级服务真正释放时调用，退出阅读页不调。
  Future<void> dispose();
}
