import 'dart:async';

/// 快照期间固定书籍文件；已有导入/删除先收尾，后来请求等待快照完成。
class LibraryFileGate {
  int _active = 0;
  Completer<void>? _frozen;
  Completer<void>? _idle;

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
