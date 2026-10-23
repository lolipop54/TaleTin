/// 听书的只读状态与真实音色（离线听书实现计划 第 5、10 节）。
///
/// 纯 Dart 不可变模型：界面看到的「正在播放 / 已暂停 / 当前句」都从这里取，
/// 不由界面自己再记一份（避免出现两份 `ttsPlaying` 互相打脸）。
library;

import 'locator.dart';
import 'speech_unit.dart';

/// 听书状态机。
///
/// [preparing] 是「已经点了开始、还在准备引擎/正文」的中间态：
/// 此时还没有声音，界面必须显示准备中，不能显示正在播放。
/// [error] 保留最后位置并提供重试，不等于会话结束。
enum TtsStatus {
  /// 没有听书会话（默认）
  idle,

  /// 已请求开始，正在准备引擎、音色与正文
  preparing,

  /// 确认在发声（收到过 started 事件）
  playing,

  /// 用户暂停，保留当前句与续播点
  paused,

  /// 用户停止，高亮与通知都已撤掉
  stopped,

  /// 自然读到全书末尾
  completed,

  /// 出错停下，保留最后位置
  error,
}

/// 音色的离线可用性（实现计划第 10 节）。
///
/// `isNetworkConnectionRequired=false` 只是候选依据，不等于断网验证通过：
/// 只有用户在断网状态下试听成功，才升级到 [offlineVerified]。
enum VoiceVerification {
  /// 候选：引擎自称不需要联网，尚未断网验证
  candidate,

  /// 已在断网状态试听通过
  offlineVerified,

  /// 不可用：引擎明确需要联网，或语音数据未安装
  unavailable,
}

/// 一个真实音色。
///
/// 只由引擎枚举结果构造，不使用「男声 / 女声」这一类假选项（实现计划第 2 节）。
class OfflineVoice {
  const OfflineVoice({
    required this.enginePackage,
    required this.voiceId,
    required this.displayName,
    required this.locale,
    required this.requiresNetwork,
    required this.isInstalled,
    this.verification = VoiceVerification.candidate,
  });

  /// 引擎包名，例如 com.google.android.tts
  final String enginePackage;

  /// 音色名（`Voice.getName()`），持久化与切换都用它
  final String voiceId;

  /// 给用户看的名字；系统不给名字时退回 [voiceId]
  final String displayName;

  /// 形如 zh-CN；取不到时为空串
  final String locale;

  /// 引擎自称需要联网。为 true 一定不是离线音色
  final bool requiresNetwork;

  /// 语音数据是否已就绪。
  ///
  /// Android 的 Voice 接口不直接给出「已安装」：引擎能把它列出来就说明引擎愿意用，
  /// 但语音数据是不是真的在本地，只有断网试听才算数。所以这个字段只用于展示，
  /// 离线结论一律看 [verification]。
  final bool isInstalled;

  final VoiceVerification verification;

  OfflineVoice copyWith({VoiceVerification? verification}) => OfflineVoice(
    enginePackage: enginePackage,
    voiceId: voiceId,
    displayName: displayName,
    locale: locale,
    requiresNetwork: requiresNetwork,
    isInstalled: isInstalled,
    verification: verification ?? this.verification,
  );

  @override
  bool operator ==(Object other) =>
      other is OfflineVoice &&
      enginePackage == other.enginePackage &&
      voiceId == other.voiceId &&
      locale == other.locale &&
      requiresNetwork == other.requiresNetwork &&
      isInstalled == other.isInstalled &&
      verification == other.verification;

  @override
  int get hashCode => Object.hash(
    enginePackage,
    voiceId,
    locale,
    requiresNetwork,
    isInstalled,
    verification,
  );

  @override
  String toString() =>
      'OfflineVoice($enginePackage/$voiceId·${locale.isEmpty ? '?' : locale})';
}

/// 定时关闭的种类（实现计划第 2、9 节）。
enum SleepPolicyKind {
  /// 不定时（默认）
  off,

  /// 按经过的分钟数倒计时；暂停期间继续计时
  minutes,

  /// 读完当前逻辑章节就停止；手动换章会取消这一种
  chapterEnd,
}

/// 定时关闭设置。
///
/// 只是「设定」，真实剩余时间由 [ListeningState.remaining] 给出：
/// 倒计时按单调时钟的截止值算，不是每秒减一。
class SleepPolicy {
  /// 不定时（默认）
  const SleepPolicy.off() : kind = SleepPolicyKind.off, minutes = 0;

  /// 自定义分钟数，范围 1–180
  const SleepPolicy.minutes(this.minutes) : kind = SleepPolicyKind.minutes;

  /// 读完本章
  const SleepPolicy.chapterEnd()
    : kind = SleepPolicyKind.chapterEnd,
      minutes = 0;

  final SleepPolicyKind kind;

  /// 仅 [SleepPolicyKind.minutes] 有意义
  final int minutes;

  bool get isOff => kind == SleepPolicyKind.off;

  @override
  bool operator ==(Object other) =>
      other is SleepPolicy && kind == other.kind && minutes == other.minutes;

  @override
  int get hashCode => Object.hash(kind, minutes);

  @override
  String toString() => switch (kind) {
    SleepPolicyKind.off => 'SleepPolicy.off',
    SleepPolicyKind.minutes => 'SleepPolicy.minutes($minutes)',
    SleepPolicyKind.chapterEnd => 'SleepPolicy.chapterEnd',
  };
}

/// copyWith 用「没传这个参数」和「显式传 null」的区分标记。
///
/// 没有它就没法把 [ListeningState.error]、[ListeningState.remaining] 从有值改回空。
const Object _absent = Object();

/// 听书的只读快照。
///
/// 默认是 [TtsStatus.idle] 的空会话，可以直接 `const ListeningState()`。
class ListeningState {
  const ListeningState({
    this.status = TtsStatus.idle,
    this.desiredPlaying = false,
    this.followReading = true,
    this.previewing = false,
    this.bookId = '',
    this.logicalChapterId = '',
    this.bookTitle = '',
    this.chapterTitle = '',
    this.currentSentence = '',
    this.voice,
    this.speed = 1.0,
    this.sleepPolicy = const SleepPolicy.off(),
    this.remaining,
    this.error,
    this.notice,
    this.sessionEpoch = 0,
    this.confirmedLocator,
    this.resumeLocator,
    this.activeUnit,
  });

  final TtsStatus status;

  /// 用户的意图（想播放 / 想暂停），与 [status] 分开。
  ///
  /// 点了播放到真的发声之间有读章节、初始化引擎等异步步骤，
  /// 界面文案必须看 [status]，只有「要不要继续推进队列」才看这里。
  final bool desiredPlaying;

  /// 手动阅读接管后保持暂停，但不再把页面拉回旧朗读位置。
  final bool followReading;

  /// 试听仅用于音频焦点与媒体服务准备，不代表正文正在播放。
  final bool previewing;

  /// 没有会话时为空串
  final String bookId;

  /// 当前逻辑章节的稳定 ID（可能跨多个正文文件）
  final String logicalChapterId;
  final String bookTitle;
  final String chapterTitle;

  /// 当前句原文，面板直接显示
  final String currentSentence;

  /// 正在使用的音色；未选定时为 null
  final OfflineVoice? voice;

  /// 语速倍率，0.5–2.0，相对引擎默认语速
  final double speed;

  final SleepPolicy sleepPolicy;

  /// 定时剩余（界面显示用）；[SleepPolicy.isOff] 时为 null
  final Duration? remaining;

  /// 出错时的中文提示；正常时为 null
  final String? error;

  /// 操作提示（例如手动换章取消章末定时），与播放错误分开。
  final String? notice;

  /// 会话代号：切书、停止、换章时递增，用来作废旧回调
  final int sessionEpoch;

  /// 最近一次**已确认**播放到的位置（started/range/done 推进），进度保存以它为准
  final Locator? confirmedLocator;

  /// 续播点：暂停或停止后下一次从这里接着读
  final Locator? resumeLocator;

  /// 已开始朗读（或暂停换章后待播）的单元，界面取其整句范围。
  final SpeechUnit? activeUnit;

  /// 是否有正在进行的会话（含准备中、暂停、出错待重试）。
  ///
  /// 停止与读完不算会话：进度已经保存，面板回到「已停止」。
  bool get hasSession =>
      status != TtsStatus.idle &&
      status != TtsStatus.stopped &&
      status != TtsStatus.completed;

  bool get isPlaying => status == TtsStatus.playing;

  /// 显示跟随与播放会话分开：锁屏期间定时停止或读完，解锁仍应追到
  /// 最后实际读到的位置。手动阅读接管后 followReading=false，不再拉回。
  Locator? get pageFollowLocator {
    if (!followReading || status == TtsStatus.idle) return null;
    return status == TtsStatus.paused ? resumeLocator : confirmedLocator;
  }

  /// 空会话（默认状态），等价于 `const ListeningState()`。
  static const ListeningState initial = ListeningState();

  ListeningState copyWith({
    TtsStatus? status,
    bool? desiredPlaying,
    bool? followReading,
    bool? previewing,
    String? bookId,
    String? logicalChapterId,
    String? bookTitle,
    String? chapterTitle,
    String? currentSentence,
    Object? voice = _absent,
    double? speed,
    SleepPolicy? sleepPolicy,
    Object? remaining = _absent,
    Object? error = _absent,
    Object? notice = _absent,
    int? sessionEpoch,
    Object? confirmedLocator = _absent,
    Object? resumeLocator = _absent,
    Object? activeUnit = _absent,
  }) => ListeningState(
    status: status ?? this.status,
    desiredPlaying: desiredPlaying ?? this.desiredPlaying,
    followReading: followReading ?? this.followReading,
    previewing: previewing ?? this.previewing,
    bookId: bookId ?? this.bookId,
    logicalChapterId: logicalChapterId ?? this.logicalChapterId,
    bookTitle: bookTitle ?? this.bookTitle,
    chapterTitle: chapterTitle ?? this.chapterTitle,
    currentSentence: currentSentence ?? this.currentSentence,
    voice: identical(voice, _absent) ? this.voice : voice as OfflineVoice?,
    speed: speed ?? this.speed,
    sleepPolicy: sleepPolicy ?? this.sleepPolicy,
    remaining: identical(remaining, _absent)
        ? this.remaining
        : remaining as Duration?,
    error: identical(error, _absent) ? this.error : error as String?,
    notice: identical(notice, _absent) ? this.notice : notice as String?,
    sessionEpoch: sessionEpoch ?? this.sessionEpoch,
    confirmedLocator: identical(confirmedLocator, _absent)
        ? this.confirmedLocator
        : confirmedLocator as Locator?,
    resumeLocator: identical(resumeLocator, _absent)
        ? this.resumeLocator
        : resumeLocator as Locator?,
    activeUnit: identical(activeUnit, _absent)
        ? this.activeUnit
        : activeUnit as SpeechUnit?,
  );

  @override
  String toString() =>
      'ListeningState(${status.name}'
      '${bookId.isEmpty ? '' : '·$bookId'}'
      '${logicalChapterId.isEmpty ? '' : '·$logicalChapterId'}'
      '${desiredPlaying ? '·desired' : ''}'
      '${error == null ? '' : '·$error'})';
}
