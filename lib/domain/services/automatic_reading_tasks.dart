/// 应用级交接入口。只登记可见阅读器的停止动作，不保存正文或统计总数。
class AutomaticReadingTasks {
  final _readers = <Object, ({String bookId, Future<void> Function() stop,
    void Function()? changed})>{};
  final _blocked = <String, int>{};
  int _allBlocks = 0;

  bool canStart(String bookId) => _allBlocks == 0 && !_blocked.containsKey(bookId);

  /// 删除/重解析期间连新的开始请求也阻止；失败或完成后由 finally 释放。
  Future<void Function()> suspendBook(String bookId) async {
    _blocked.update(bookId, (count) => count + 1, ifAbsent: () => 1);
    var released = false;
    void release() {
      if (released) return;
      released = true;
      final count = _blocked[bookId]! - 1;
      if (count == 0) { _blocked.remove(bookId); } else { _blocked[bookId] = count; }
    }
    try {
      for (final reader in _readers.values.toList()) {
        if (reader.bookId == bookId) await reader.stop();
      }
      return release;
    } catch (_) { release(); rethrow; }
  }

  /// 完整备份恢复的接入点：调用方还需等待其他正文读写并在 finally 释放。
  Future<void Function()> suspendAll() async {
    _allBlocks++;
    var released = false;
    void release() { if (!released) { released = true; _allBlocks--; } }
    try { await stopAll(); return release; } catch (_) { release(); rethrow; }
  }

  void attach(Object owner, String bookId, Future<void> Function() stop,
      {void Function()? changed}) {
    _readers[owner] = (bookId: bookId, stop: stop, changed: changed);
  }

  void contentChanged(String bookId) {
    for (final reader in _readers.values.toList()) {
      if (reader.bookId == bookId) reader.changed?.call();
    }
  }

  void detach(Object owner) => _readers.remove(owner);

  /// 通知栏与面板播放共用此等待，停止、撤图、位置写入完成后才能发声。
  Future<void> stopAll() async {
    for (final reader in _readers.values.toList()) {
      await reader.stop();
    }
  }
}
