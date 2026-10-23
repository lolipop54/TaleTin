import 'dart:async';

import 'app_errors.dart';

/// 每次恢复最多记录八个跟随步骤，不记录正文、书名、书籍或章节 ID。
/// 与异常日志分开轮换；从设置页导出错误日志时一并导出。
class ListeningFollowDiagnostics {
  ListeningFollowDiagnostics(this.layout);
  final String layout;
  int _remaining = 0;

  void lifecycle(String state, Map<String, Object?> details) {
    if (state == 'resumed') _remaining = 8;
    _write('lifecycle', {'lifecycle': state, ...details});
  }

  void step(String event, Map<String, Object?> details) {
    if (_remaining <= 0) return;
    _remaining--;
    _write(event, details);
  }

  void _write(String event, Map<String, Object?> details) {
    unawaited(
      AppErrors.store
          .appendListeningFollow({
            'kind': 'listeningFollow',
            'time': DateTime.now().toIso8601String(),
            'layout': layout,
            'event': event,
            ...details,
          })
          .catchError((Object _) {}),
    );
  }
}
