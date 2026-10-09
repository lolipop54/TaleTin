import 'dart:async';

import '../../../domain/services/listening_deadline.dart';

/// 倒计时的截止点只在用户设置时改变，播放/暂停/切音色不会重置。
class ListeningSleepTimer {
  ListeningSleepTimer(
    this.clock,
    this.onRemaining,
    this.onExpired,
    this.onError,
  ) {
    _events = clock.expired.listen((version) {
      if (version == _version && _deadline != null) _expire();
    });
  }
  final ListeningDeadline clock;
  final void Function(Duration) onRemaining;
  final void Function() onExpired;
  final void Function(Object) onError;
  late final StreamSubscription<int> _events;
  Timer? _ticker;
  int? _deadline;
  // 同一平台通道中重建控制器也不能复用旧提醒版本。
  static int _generation = 0;
  int _version = 0;
  bool _checking = false;
  Future<void> _tail = Future.value();

  Future<void> setMinutes(int? minutes) {
    final version = _version = ++_generation;
    _deadline = null;
    _ticker?.cancel();
    final result = _tail.then((_) async {
      if (version != _version) return;
      final deadline = minutes == null
          ? null
          : await clock.now() + minutes * 60000;
      if (version != _version) return;
      _deadline = deadline;
      await clock.arm(version, deadline);
      if (version != _version || deadline == null) return;
      await check();
      if (version != _version || _deadline == null) return;
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (_checking) return;
        _checking = true;
        check()
            .catchError((Object error) {
              onError(error);
              return true;
            })
            .whenComplete(() => _checking = false);
      });
    });
    _tail = result.catchError((Object _) {});
    return result;
  }

  /// 每次提交/恢复前检查，包括暂停期间 CPU 曾休眠的情况。
  Future<bool> check() async {
    final deadline = _deadline;
    final version = _version;
    if (deadline == null) return false;
    final remaining = deadline - await clock.now();
    if (version != _version || _deadline != deadline) return false;
    if (remaining <= 0) {
      _expire();
      return true;
    }
    onRemaining(Duration(milliseconds: remaining));
    return false;
  }

  void _expire() {
    _deadline = null;
    _ticker?.cancel();
    onExpired();
  }

  Future<void> dispose() async {
    await setMinutes(null);
    await _events.cancel();
  }
}
