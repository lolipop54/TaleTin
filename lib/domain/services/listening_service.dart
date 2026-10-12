/// 听书服务契约（离线听书实现计划 第 5、7 节）。
///
/// 这是界面唯一能拿到的听书入口：播放队列、逻辑章节、位置保存都在实现里，
/// 界面只读 [state] 和 [snapshot]、只调这里的命令。
library;

import '../models/locator.dart';
import '../models/tts_state.dart';
import 'tts_engine.dart';

/// 听书服务。
///
/// 生命周期是应用级的：由后台媒体服务保活，不随阅读页释放；
/// 因此实现不能持有 BuildContext，也不能依赖活跃的 WebView
/// （后台换章要能从源内容与缓存算出位置）。
abstract class ListeningService {
  /// 只读状态流。
  ///
  /// 事件处理、命令执行都在这条流上按顺序体现，界面按它刷新即可。
  Stream<ListeningState> get state;

  /// 当前快照（同步读）。刚打开面板时先用它占位，避免闪一下空状态。
  ListeningState get snapshot;

  /// 准备设置和真实音色；打开面板不发声，也不中断已有播放。
  Future<List<OfflineVoice>> prepareVoices();
  Future<List<TtsEngineInfo>> listEngines();
  Future<List<OfflineVoice>> detectVoices(String? enginePackage);

  /// 独立试听任务；先暂停正文，结束后仍保持暂停，不更新阅读位置。
  Future<void> previewVoice(OfflineVoice voice);

  /// 可见阅读页提供的页首；页面隐藏/释放时传空。只拆后续任务，不中断发声。
  void setPageBoundaries(Object owner, List<Locator> boundaries);

  /// 从 [locator] 所在的句子开始听。
  ///
  /// 已有同一本书的暂停会话、且用户没有手动移位时，接着那个会话读；
  /// 首次打开面板不会因为调用了它以外的操作就自动发声。
  /// 锚点落在图片上时，从它后面第一段可读文本开始。
  /// [sentenceStart] 为 false 时从精确锚点开始，供阅读页首次开始或重新开始使用。
  Future<void> start(
    String bookId,
    Locator locator, {
    bool sentenceStart = true,
  });

  /// 继续播放（暂停后从续播点接着读）。
  Future<void> play();

  /// 暂停：立即停止发声，保留当前句、高亮与续播点。
  ///
  /// 引擎没有真正的暂停，实现会从最近一次已确认的位置重播，
  /// 允许重读极小一段，但不跳过没有确认过的内容。
  Future<void> pause();

  /// 用户翻页/跳转前暂停并交回位置保存权，等待在途保存结束。
  Future<void> takeOverReading(String bookId);

  /// 接管后的新阅读落点同时成为通知与面板下次开始的位置。
  void updateReadingPosition(Locator locator);

  /// 停止：停止发声、清空待播队列、撤掉高亮与媒体通知、取消定时、保存位置。
  ///
  /// 不跳回章首、不退出应用，也不重置阅读进度。重复调用是幂等的。
  Future<void> stop();

  /// 上一逻辑章：按书内目录的可定位条目切换，落到目标条目起点。
  ///
  /// 播放中点换章后继续播放，暂停中点换章后保持暂停。
  Future<void> previousChapter();

  /// 下一逻辑章。
  Future<void> nextChapter();

  /// 换音色。
  ///
  /// 记住原来的播放/暂停意图和续读点，配置成功后从续读点重建；
  /// 失败时保留原音色、不静默切到需要联网的音色，并返回 false。
  Future<bool> setVoice(OfflineVoice voice);

  /// 改语速（0.5–2.0，步长 0.1，越界由实现夹紧）。
  ///
  /// 暂停时只改配置不自动播放；正在播放时从续读点继续，不跳句、不双播。
  Future<void> setRate(double rate);

  /// 改定时关闭设置。
  ///
  /// 不改变播放状态；普通调用保留原截止点。
  /// 睡眠面板收起传 restartTimer:true，已经计时的分钟策略从当前时间重新计时。
  Future<void> setSleepPolicy(SleepPolicy policy, {String? bookId, bool restartTimer = false});
}
