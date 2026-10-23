import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// 错误与退出过程分别轮换，不放进书库或可清理的阅读缓存。
class AppErrorStore {
  AppErrorStore({
    Future<Directory> Function()? directory,
    this.maxBytes = 524288,
    this.exitMaxBytes = 131072,
  }) : _directory = directory ?? getApplicationSupportDirectory;

  final Future<Directory> Function() _directory;
  final int maxBytes;
  final int exitMaxBytes;
  final Map<String, Object?> environment = {};
  Future<void> _tail = Future.value();

  // 导出快照与轮换也共用写入顺序，避免导出期间某份文件被新错误重命名。
  Future<T> _serial<T>(Future<T> Function() action) {
    final next = _tail.then((_) => action());
    _tail = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  Future<File> _file(String name) async {
    final root = await _directory();
    final folder = Directory('${root.path}/diagnostics');
    await folder.create(recursive: true);
    return File('${folder.path}/$name');
  }

  Future<void> append(Map<String, Object?> event) =>
      _serial(() => _append(event, 'errors', maxBytes));

  /// 正常退出过程单独轮换，不能挤掉真实异常，也不进入错误提示队列。
  Future<void> appendReaderExit(Map<String, Object?> event) =>
      _serial(() => _append(event, 'reader-exit', exitMaxBytes));

  Future<void> appendListeningFollow(Map<String, Object?> event) =>
      _serial(() => _append(event, 'listening-follow', exitMaxBytes));

  Future<void> _append(
    Map<String, Object?> event,
    String name,
    int limit,
  ) async {
    final file = await _file('$name.jsonl');
    final bytes = utf8.encode('${jsonEncode(event)}\n');
    if (await file.exists() && await file.length() + bytes.length > limit) {
      final previous = await _file('$name.previous.jsonl');
      if (await previous.exists()) await previous.delete();
      await file.rename(previous.path);
    }
    // 崩溃可能打断上一条写入；先分开残留行，不能把下一条记录接进半个JSON。
    if (await file.exists() && await file.length() > 0) {
      final input = await file.open();
      var terminated = false;
      try {
        await input.setPosition(await input.length() - 1);
        terminated = await input.readByte() == 10;
      } finally {
        await input.close();
      }
      if (!terminated) {
        await file.writeAsBytes([10], mode: FileMode.append, flush: true);
      }
    }
    await file.writeAsBytes(bytes, mode: FileMode.append, flush: true);
  }

  Future<String> exportText() => _serial(_exportText);

  Future<String> _exportText() async {
    final result = StringBuffer()
      ..writeln('TaleTin 本地错误日志')
      ..writeln(
        jsonEncode({
          'exportedAt': DateTime.now().toIso8601String(),
          'environment': environment,
        }),
      );
    for (final name in [
      'errors.previous.jsonl',
      'errors.jsonl',
      'reader-exit.previous.jsonl',
      'reader-exit.jsonl',
      'listening-follow.previous.jsonl',
      'listening-follow.jsonl',
    ]) {
      final file = await _file(name);
      if (await file.exists()) {
        result.write(
          utf8.decode(await file.readAsBytes(), allowMalformed: true),
        );
      }
    }
    return result.toString();
  }
}
