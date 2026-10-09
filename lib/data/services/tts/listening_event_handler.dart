part of 'listening_controller.dart';

/// 执行已经解析好的引擎动作；所有字段仍属于唯一的播放控制器。
extension _ListeningEventHandler on ListeningController {
  void _onEvent(TtsEngineEvent event) {
    final action = parseListeningEngineEvent(
      event: event,
      activeId: _activeId,
      desiredPlaying: snapshot.desiredPlaying,
      started: _started,
      sentOffset: _sentOffset,
      resumeOffset: _resumeOffset,
      unit: _unit,
    );
    if (action is IgnoreListeningEvent) return;
    final unit = _unit!;
    if (action is ConfirmListeningStart) {
      _started = true;
      _emit(
        snapshot.copyWith(
          status: TtsStatus.playing,
          logicalChapterId: unit.logicalChapterId,
          currentSentence: unit.sentenceText,
          activeUnit: unit,
          confirmedLocator: action.position,
          resumeLocator: action.position,
        ),
      );
    } else if (action is ConfirmListeningRange) {
      _resumeOffset = action.offset;
      _emit(
        snapshot.copyWith(
          confirmedLocator: action.position,
          resumeLocator: action.position,
        ),
      );
    } else if (action is CompleteListeningUnit) {
      // 先撤销资格再等待下一窗口，重复 done 无法重复提交。
      _activeId = null;
      _watchdog?.cancel();
      _unit = null;
      _emit(
        snapshot.copyWith(
          confirmedLocator: unit.endLocator,
          resumeLocator: unit.endLocator,
          status: TtsStatus.preparing,
        ),
      );
      final epoch = _epoch;
      unawaited(_guard(epoch, () => _advance(epoch)));
    } else if (action is FailListeningUnit) {
      unawaited(_finish(TtsStatus.error, error: '语音播放失败（${action.code.name}）'));
    } else if (action is StopListeningUnit) {
      // 外部打断保留续播点，绝不把 stopped 当作读完。
      unawaited(pause());
    }
  }
}
