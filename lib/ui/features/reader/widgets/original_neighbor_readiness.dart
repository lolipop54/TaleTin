import 'dart:async';

/// 邻章的就绪通知与边界补齐任务。每次等待独立结束，超时不误删其他等待者。
class OriginalNeighborReadiness {
  final _waiting = <int, Set<Completer<bool>>>{};
  final _boundaries = <Object, Future<bool>>{};

  Future<bool> wait(int chapter, Duration timeout) async {
    final ready = Completer<bool>();
    (_waiting[chapter] ??= {}).add(ready);
    try {
      return await ready.future.timeout(timeout);
    } finally {
      final waiting = _waiting[chapter];
      waiting?.remove(ready);
      if (waiting?.isEmpty == true) _waiting.remove(chapter);
    }
  }

  void complete(int chapter, bool ready) {
    final waiting = _waiting.remove(chapter);
    if (waiting == null) return;
    for (final result in waiting) {
      if (!result.isCompleted) result.complete(ready);
    }
  }

  Future<bool> prepareBoundary(Object key, Future<bool> Function() prepare) =>
      _boundaries.putIfAbsent(key, () {
        return Future<bool>.sync(prepare).whenComplete(() {
          // 不能返回 remove 的值：它正是当前 Future，会让任务等待自己。
          _boundaries.remove(key);
        });
      });

  void cancelAll() {
    for (final chapter in _waiting.keys.toList()) {
      complete(chapter, false);
    }
  }
}
