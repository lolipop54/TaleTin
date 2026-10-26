// 离线听书的原生 TTS 通道定义（docs/离线听书实现计划.md 第 5 节）。
//
// 生成命令：
//   dart run pigeon --input pigeons/tts_api.dart \
//     --dart_out lib/platform/channels/tts_api.g.dart \
//     --kotlin_out android/app/src/main/kotlin/com/example/gtreader/tts/TtsApi.g.kt \
//     --kotlin_package com.example.gtreader.tts --package_name gtreader
//
// 为什么单独一个文件和单独的 Kotlin 包：pigeon 会给每个文件生成一份 `FlutterError`，
// 与 document_host_api.dart 的生成物放同一个 Kotlin 包会重复声明（见那个文件顶部的说明）。
// 分包的代价是两边的 Dart 生成文件各有一个同名 `FlutterError` 类，各自包装里只导入其中一个。
//
// 约定（来自实现计划第 5、7 节）：
// - 每个 speak 都带唯一 ID，事件回调把「事件自己的 ID」原样回传，绝不用「当前 ID」顶替；
// - 通道返回成功只代表请求已被接收，真的开始发声以 started 事件为准；
// - 范围回调的偏移相对本次发送的文本，Dart 侧自己换算回原文位置。
import 'package:pigeon/pigeon.dart';

/// 一个可用的 TTS 引擎（系统里可被选中的语音合成应用）。
class TtsEngineDto {
  TtsEngineDto({
    required this.packageName,
    required this.label,
    required this.isDefault,
  });

  /// 引擎包名，例如 com.google.android.tts；也是重新初始化时传给原生桥的标识
  String packageName;

  /// 给用户看的名字；系统不给名字时退回包名
  String label;

  /// 是否为系统当前默认引擎
  bool isDefault;
}

/// 一个音色。[Android Voice](https://developer.android.com/reference/android/speech/tts/Voice)
class TtsVoiceDto {
  TtsVoiceDto({
    required this.name,
    required this.locale,
    required this.isNetworkRequired,
    required this.quality,
    required this.latency,
    required this.features,
  });

  /// 音色名（Voice.getName()），持久化与 setVoice 都用它
  String name;

  /// 形如 zh-CN；取不到时为空串
  String locale;

  /// 引擎自称需要联网。为 true 的音色一定不是离线音色；
  /// 为 false 只是候选，是否真离线要断网试听才知道（第 10 节）
  bool isNetworkRequired;

  /// Voice.QUALITY_*，用于排序展示
  int quality;

  /// Voice.LATENCY_*，用于排序展示
  int latency;

  /// Voice.getFeatures() 的特性名集合（如 "networkTimeoutMs"）。
  /// 注意不是位掩码：Android 的 Voice.getFeatures() 返回 Set&lt;String&gt;。
  List<String> features;
}

/// 初始化结果。失败时 `errorCode` 说明原因，界面据此提示而不是静默降级。
class TtsInitResultDto {
  TtsInitResultDto({
    required this.ok,
    required this.enginePackage,
    this.errorCode,
    this.message,
  });

  bool ok;

  /// 实际生效的引擎包名（传 null 时是系统默认引擎）
  String enginePackage;

  TtsErrorCode? errorCode;

  /// 原生侧原始信息，仅用于排查；中文提示由 Dart 侧按 errorCode 生成
  String? message;
}

/// 错误码。与 Android TextToSpeech 的 ERROR_* 常量对应，未知值一律落到 other。
enum TtsErrorCode {
  /// 初始化失败（引擎不可用、语音数据缺失）
  init,

  /// 合成失败
  synthesis,

  /// 音频输出失败（没有可用输出设备）
  output,

  /// 网络相关错误；离线音色不应出现，出现说明引擎在偷偷联网
  network,

  /// 网络超时
  networkTimeout,

  /// 引擎服务异常
  service,

  /// 引擎不支持这个语言
  unsupportedLanguage,

  /// 指定音色/引擎未安装
  notInstalled,

  /// 入参不合法（例如文本为空、ID 重复）
  invalidRequest,

  /// 其他未归类错误
  other,
}

/// 原生 TTS 的能力接口。
///
/// 只在应用级插件里注册一次，不依赖 Activity：Activity 退出、锁屏、返回书架
/// 都要能继续读下一句（实现计划第 5 节）。
///
/// **连接和播放操作走 Pigeon 的串行后台线程**：
/// `TextToSpeech` 的 `onInit` 回调由 `ServiceConnection` 派发，**一定在主线程**；
/// 如果宿主方法跑在主线程上，[initialize] 里「等初始化结果」就是主线程等自己，
/// 必然等到超时（真机实测：两次 15 秒超时，A2b 第二轮起全部失败）。
/// 引擎清单只查包管理器，走独立的默认队列，不等待正在连接的引擎。
@HostApi()
abstract class TtsHostApi {
  @TaskQueue(type: TaskQueueType.serialBackgroundThread)
  int elapsedRealtime();

  /// null 取消提醒；版本号隔离迟到的设置与回调。
  @TaskQueue(type: TaskQueueType.serialBackgroundThread)
  void setSleepDeadline(int version, int? deadlineMs);

  /// 初始化（或换引擎后重新初始化）TTS。传 null 用系统默认引擎。
  /// 真正等待引擎就绪，失败通过 [TtsInitResultDto.ok] 返回，不抛异常。
  @TaskQueue(type: TaskQueueType.serialBackgroundThread)
  TtsInitResultDto initialize(String? enginePackage);

  /// 取消尚未完成的连接。独立队列立即唤醒 initialize，不能排在其等待后面。
  void cancelInitialization();

  /// 系统里可见的 TTS 引擎清单；始终包含系统默认引擎。
  List<TtsEngineDto> listEngines();

  /// 当前引擎的音色清单。需要先 [initialize]。
  @TaskQueue(type: TaskQueueType.serialBackgroundThread)
  List<TtsVoiceDto> listVoices();

  /// 切换音色（同一引擎内）。名称不存在时返回 false，调用方保留原音色。
  @TaskQueue(type: TaskQueueType.serialBackgroundThread)
  bool setVoice(String voiceName, String? locale);

  /// 设置语速倍率，相对引擎默认语速（实现计划 2.：不承诺时长精确成倍）。
  @TaskQueue(type: TaskQueueType.serialBackgroundThread)
  void setRate(double rate);

  /// 提交一段文本。返回即代表请求已受理，是否真的开始读由 started 事件确认。
  @TaskQueue(type: TaskQueueType.serialBackgroundThread)
  void speak(String utteranceId, String text);

  /// 停止发声并丢弃未播内容。用户主动暂停也走这里。
  /// 只释放引擎，不销毁线程：之后还能再 [initialize]（在 Dart 侧就是停止听书后重新开始）。
  @TaskQueue(type: TaskQueueType.serialBackgroundThread)
  void stop();

  /// 提示音等短暂抢占期间按住发声：暂停当前音频但保留播放位置，
  /// 不改正文、不丢合成结果，等 [resumeSpeech] 从同一帧继续。
  @TaskQueue(type: TaskQueueType.serialBackgroundThread)
  void holdSpeech();

  /// 从 [holdSpeech] 停住的位置继续发声；没有按住的音频时什么也不做。
  @TaskQueue(type: TaskQueueType.serialBackgroundThread)
  void resumeSpeech();

  /// 释放引擎并结束原生线程。只在引擎 detach（应用真正退出）时调用；
  /// 调用后这个插件实例不能再初始化。
  @TaskQueue(type: TaskQueueType.serialBackgroundThread)
  void shutdown();

  /// 引擎单次可接受的最大文本长度（UTF-16 单元），用于长句拆分上限。
  @TaskQueue(type: TaskQueueType.serialBackgroundThread)
  int maxSpeechInputLength();

  /// 当前引擎是否支持该语言（BCP-47，例如 zh-CN）。
  @TaskQueue(type: TaskQueueType.serialBackgroundThread)
  bool isLanguageAvailable(String locale);
}

/// 原生侧主动上报的播放事件。
///
/// 所有回调都在平台主线程发出（TTS 回调本来就在主线程），
/// Dart 侧在同一控制器里串行消费。
@FlutterApi()
abstract class TtsEventsFlutterApi {
  void onSleepDeadline(int version);

  /// 该 utterance 确认开始发声。
  void onStarted(String utteranceId);

  /// 正在朗读 [start, end) 这段（相对本次发送的文本，UTF-16 偏移）。
  void onRangeStart(String utteranceId, int start, int end);

  /// 该 utterance 全部读完。
  void onDone(String utteranceId);

  /// 被 stop 或引擎打断；`interrupted` 为 true 表示不是我们主动停的。
  void onStopped(String utteranceId, bool interrupted);

  /// 出错。事件带自己的 ID，Dart 侧据此判断是否属于当前会话。
  void onError(String utteranceId, TtsErrorCode code, String message);
}
