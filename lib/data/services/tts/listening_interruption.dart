part of 'listening_controller.dart';

/// 提示音等「可被压低」的短暂抢占：只按住发声，等系统交还焦点再继续。
///
/// 与暂停的区别：不改播放状态、不释放焦点、不丢已合成音频，
/// 所以界面和媒体通知不会闪一下暂停又跳回来，续播也从同一帧继续。
extension ListeningInterruptionHandling on ListeningController {
  /// 按住发声（通知提示音、导航播报等）。
  ///
  /// 只在「用户想播放、确实在播放或准备」时生效。按住期间取消语音回调超时看门狗；
  /// 超过 [promptHoldLimit] 系统仍不归还焦点，就转为普通暂停，避免显示在播却没声音。
  Future<void> holdForInterruption() async {
    if (_disposed || _promptHold != null) return;
    if (!snapshot.desiredPlaying || snapshot.previewing) return;
    if (snapshot.status != TtsStatus.playing &&
        snapshot.status != TtsStatus.preparing) {
      return;
    }
    _promptHold = Timer(promptHoldLimit, () {
      // 一直不还焦点：当作真正的打断，转普通暂停，用户可以手动继续。
      _promptHold = null;
      unawaited(pause());
    });
    _watchdog?.cancel();
    final epoch = _epoch;
    try {
      await _command(epoch, engine.holdSpeech);
    } catch (error, appStack) {
      // 按住失败最多和提示音同时响，不能因此把正常朗读判成错误。
      AppErrors.report(error, appStack, operation: '按住发声等待提示音失败');
    }
  }

  /// 系统确认焦点已归还后继续。
  ///
  /// 是否真的继续要重新核对：按住可能已被暂停、停止、换书、手动翻页、定时到期
  /// 作废；期间也可能来了电话或别的音乐（已转普通暂停）。任何一项变了都不恢复。
  Future<void> resumeAfterInterruption() async {
    final hold = _promptHold;
    if (_disposed || hold == null) return;
    hold.cancel();
    _promptHold = null;
    if (!snapshot.desiredPlaying || snapshot.previewing) return;
    final epoch = _epoch;
    try {
      await _command(epoch, () async {
        // 命令排队期间状态可能已经变了（暂停、换章、到时），必须再确认一次。
        if (_promptHold != null || !_current(epoch)) return;
        if (!snapshot.desiredPlaying) return;
        await engine.resumeSpeech();
        if (_current(epoch)) _armWatchdog();
      });
    } catch (error, appStack) {
      AppErrors.report(error, appStack, operation: '继续朗读失败');
      // 续播失败不能让界面一直显示在播却没声音：回到普通暂停，由用户决定。
      if (_current(epoch)) await pause();
    }
  }
}
