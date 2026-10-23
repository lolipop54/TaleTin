import 'dart:async';

import '../../domain/models/locator.dart';
import '../../domain/models/tts_state.dart';
import 'app_errors.dart';

/// 每次恢复观察45秒、最多240步；播放快照最多每三秒补一条。
/// 不序列化 Locator / ListeningState，避免把正文、路径和书籍身份写进日志。
/// 与异常日志分开轮换；从设置页导出错误日志时一并导出。
class ListeningFollowDiagnostics {
  ListeningFollowDiagnostics(
    this.layout, {
    Future<void> Function(Map<String, Object?>)? append,
  }) : _append = append ?? AppErrors.store.appendListeningFollow;
  final String layout;
  final Future<void> Function(Map<String, Object?>) _append;
  final String id = '${DateTime.now().microsecondsSinceEpoch}-${++_sequence}';
  static int _sequence = 0;
  final _clock = Stopwatch()..start();
  int _remaining = 0;
  int _untilMs = 0;
  int _lastPlaybackMs = -3000;
  int _resume = 0;
  final _checks = <Timer>[];

  bool get observing =>
      _remaining > 0 && _clock.elapsedMilliseconds <= _untilMs;

  void lifecycle(
    String state,
    Map<String, Object?> details, {
    Map<String, Object?> Function()? snapshot,
  }) {
    for (final timer in _checks) {
      timer.cancel();
    }
    _checks.clear();
    if (state == 'resumed') {
      _remaining = 240;
      _untilMs = _clock.elapsedMilliseconds + 45000;
      _resume++;
      if (snapshot != null) {
        // 只读快照，不请求布局或新帧。即使 post-frame 没有执行也能留下现场。
        for (final seconds in [2, 10]) {
          _checks.add(
            Timer(Duration(seconds: seconds), () {
              _write('recoverySnapshot', {
                'afterSeconds': seconds,
                ...snapshot(),
              });
            }),
          );
        }
      }
    }
    _write('lifecycle', {'lifecycle': state, ...details});
  }

  void step(String event, Map<String, Object?> details) {
    if (!observing) return;
    _remaining--;
    _write(event, details);
    if (_remaining == 0) _write('stepLimitReached', const {});
  }

  void playback(ListeningState state, ListeningState previous) {
    if (state.bookId.isEmpty) return;
    final changed =
        state.bookId != previous.bookId ||
        state.status != previous.status ||
        state.followReading != previous.followReading ||
        state.desiredPlaying != previous.desiredPlaying;
    if (!changed && _clock.elapsedMilliseconds - _lastPlaybackMs < 3000) return;
    _lastPlaybackMs = _clock.elapsedMilliseconds;
    _write('playback', {
      'foreground': AppErrors.reporter.foreground,
      ...listeningDiagnosticSnapshot(state),
      'samePositionAsPrevious':
          state.confirmedLocator != null &&
          previous.confirmedLocator?.samePosition(state.confirmedLocator!) ==
              true,
      'sameChapterAsPrevious':
          state.confirmedLocator != null &&
          state.confirmedLocator?.chapterId ==
              previous.confirmedLocator?.chapterId,
    });
  }

  void dispose() {
    for (final timer in _checks) {
      timer.cancel();
    }
    _checks.clear();
    _remaining = 0;
  }

  void _write(String event, Map<String, Object?> details) {
    unawaited(
      Future<void>.sync(
        () => _append({
          'kind': 'listeningFollow',
          'schema': 2,
          'id': id,
          'resume': _resume,
          'elapsedMs': _clock.elapsedMilliseconds,
          'time': DateTime.now().toIso8601String(),
          'layout': layout,
          'event': event,
          ...details,
        }),
      ).catchError((Object _) {}),
    );
  }
}

/// 只保留偏移及相对关系；调用方另给章序号，不保存正文、块ID或章节ID。
Map<String, Object?> listeningDiagnosticPosition(
  Locator? value, {
  Locator? relativeTo,
}) => {
  'present': value != null,
  if (value != null) ...{
    'offset': value.utf16Offset,
    'affinity': value.affinity.name,
    'contentVersion': value.contentVersion,
    'needsRelocation': value.needsRelocation,
    if (relativeTo != null) ...{
      'sameChapter': value.chapterId == relativeTo.chapterId,
      'sameBlock':
          value.chapterId == relativeTo.chapterId &&
          value.blockId == relativeTo.blockId,
      'samePosition': value.samePosition(relativeTo),
    },
  },
};

Map<String, Object?> listeningDiagnosticSnapshot(
  ListeningState state, {
  String? readerBookId,
  Locator? anchor,
}) => {
  'status': state.status.name,
  'epoch': state.sessionEpoch,
  'desiredPlaying': state.desiredPlaying,
  'followReading': state.followReading,
  'hasSession': state.hasSession,
  'hasTarget': state.pageFollowLocator != null,
  'sameBook': readerBookId == null ? null : state.bookId == readerBookId,
  'confirmed': listeningDiagnosticPosition(
    state.confirmedLocator,
    relativeTo: anchor,
  ),
  'resumePosition': listeningDiagnosticPosition(
    state.resumeLocator,
    relativeTo: anchor,
  ),
  'target': listeningDiagnosticPosition(
    state.pageFollowLocator,
    relativeTo: anchor,
  ),
  'hasUnit': state.activeUnit != null,
  'unitIsTitle': state.activeUnit?.isChapterTitle,
  'unitStartOffset': state.activeUnit?.startLocator.utf16Offset,
  'unitEndOffset': state.activeUnit?.endLocator.utf16Offset,
  'hasError': state.error != null,
};
