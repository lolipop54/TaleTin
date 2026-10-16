import 'dart:async';

/// 快照期间固定书籍文件；已有导入/删除先收尾，后来请求等待快照完成。
class LibraryFileGate {
  int _active = 0;
  Completer<void>? _frozen;
  Completer<void>? _idle;
  final _books = <String, Future<void>>{};

  /// 同一本书的自动更新与删除顺序执行，防止更新结束又把已删除的书放回书架。
  Future<void Function()> enterBook(String id) async {
    final previous = _books[id];
    final done = Completer<void>();
    _books[id] = done.future;
    if (previous != null) await previous;
    return () {
      if (done.isCompleted) return;
      if (identical(_books[id], done.future)) _books.remove(id);
      done.complete();
    };
  }

  Future<void Function()> enter() async {
    while (_frozen != null) { await _frozen!.future; }
    _active++;
    var released = false;
    return () {
      if (released) return;
      released = true;
      if (--_active == 0) { _idle?.complete(); _idle = null; }
    };
  }

  Future<void Function()> freeze() async {
    if (_frozen != null) throw StateError('已有备份或恢复正在处理');
    final frozen = _frozen = Completer<void>();
    if (_active > 0) { _idle ??= Completer<void>(); await _idle!.future; }
    var released = false;
    return () {
      if (released) return;
      released = true;
      _frozen = null;
      frozen.complete();
    };
  }
}
