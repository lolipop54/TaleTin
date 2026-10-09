import 'dart:convert';
import 'dart:io';

/// 数据库连接全部关闭后使用。日志和旧目录必须留在持久存储，不放可回收缓存。
class BackupRestoreTransaction {
  BackupRestoreTransaction(this.root, {this.onBoundary});
  final Directory root;
  final Future<void> Function(String phase)? onBoundary;
  bool _committed = false;
  static const parts = ['database', 'library', 'fonts'];
  File get journal => File('${root.path}/restore-journal.json');
  Directory get old => Directory('${root.path}/restore-old');

  Future<void> _write(Map<String, Object> value) async {
    final next = File('${journal.path}.next');
    await next.writeAsString(jsonEncode(value), flush: true);
    await next.rename(journal.path);
  }

  Future<Map<String, dynamic>> _read() async {
    final value = jsonDecode(await journal.readAsString());
    if (value is! Map<String, dynamic> || value['version'] != 1 ||
        !['switching', 'committed'].contains(value['phase']) || value['present'] is! List ||
        (value['present'] as List).any((p) => !parts.contains(p))) {
      throw const FormatException('恢复记录损坏，已停止打开书库以保留现场');
    }
    return value;
  }

  Future<void> replace(Directory staged) async {
    if (await journal.exists() || await old.exists()) throw StateError('还有未结束的恢复，请先处理');
    if (!await File('${staged.path}/database/reader.sqlite').exists()) throw const FormatException('待恢复数据库不存在');
    final present = <String>[];
    for (final part in parts) {
      if (await Directory('${root.path}/$part').exists()) present.add(part);
    }
    await _write({'version': 1, 'phase': 'switching', 'present': present});
    await old.create();
    for (final part in parts) {
      final current = Directory('${root.path}/$part');
      if (await current.exists()) await current.rename('${old.path}/$part');
      await onBoundary?.call('$part-old');
      final incoming = Directory('${staged.path}/$part');
      if (await incoming.exists()) await incoming.rename(current.path);
      await onBoundary?.call('$part-new');
    }
  }

  /// 新库和应用服务都初始化成功后，才让下一次启动保留新数据。
  Future<void> commit() async {
    final state = await _read();
    await _write({'version': 1, 'phase': 'committed', 'present': state['present'] as List});
    _committed = true;
    await onBoundary?.call('committed');
    await _cleanup();
  }

  Future<bool> isCommitted() async => _committed || (await journal.exists() && (await _read())['phase'] == 'committed');

  Future<void> rollback() async {
    if (!await journal.exists()) return;
    final state = await _read();
    if (state['phase'] == 'committed') { await _cleanup(); return; }
    // 磁盘文件被外部删除或损坏时，保留现场，不能清日志后新建一个空库。
    for (final part in state['present'] as List) {
      final previous = Directory('${old.path}/$part');
      final current = Directory('${root.path}/$part');
      final source = await previous.exists() ? previous : current;
      if (!await source.exists() || (part == 'database' &&
          !await File('${source.path}/reader.sqlite').exists())) {
        throw StateError('原有 $part 数据无法恢复，已保留恢复记录和自动快照');
      }
    }
    for (final part in parts) {
      final previous = Directory('${old.path}/$part');
      final current = Directory('${root.path}/$part');
      if (await previous.exists()) {
        if (await current.exists()) await current.delete(recursive: true);
        await previous.rename(current.path);
      } else if (!(state['present'] as List).contains(part) && await current.exists()) {
        // 原来没有的目录属于本次恢复；删除它才能回到完整的原状态。
        await current.delete(recursive: true);
      }
      await onBoundary?.call('$part-rollback');
    }
    await _cleanup();
  }

  Future<void> _cleanup() async {
    if (await old.exists()) await old.delete(recursive: true);
    if (await journal.exists()) await journal.delete();
    final next = File('${journal.path}.next');
    if (await next.exists()) await next.delete();
  }

  /// 必须早于普通书库回收。未提交一律回原数据，已提交则仅清理旧副本。
  Future<void> recover() async {
    if (await journal.exists()) { await rollback(); }
    else if (await old.exists()) { throw StateError('旧数据目录仍存在但恢复记录缺失，已保留现场'); }
  }
}
