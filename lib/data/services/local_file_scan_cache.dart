import '../../domain/services/local_book_files.dart';

/// 仅保留本次进程的文件清单；页面的选择、搜索和已导入状态不放进缓存。
class LocalFileScanCache {
  LocalFileScanSnapshot? snapshot;
  bool changed = false;
  bool uncertain = false;
  DateTime? checkedAt;
  int revision = 0;

  void publish(LocalFileScanSnapshot value) {
    snapshot = value;
    changed = value.changedDuringScan;
    uncertain = value.unreadable.isNotEmpty;
    checkedAt = null;
    revision++;
  }

  void remove(Set<String> paths) {
    final old = snapshot;
    if (old == null || paths.isEmpty) return;
    snapshot = LocalFileScanSnapshot(
      entries: old.entries.where((e) => !paths.contains(e.path)).toList(),
      directories: old.directories,
      roots: old.roots,
      indexStamp: old.indexStamp,
      unreadable: old.unreadable,
      changedDuringScan: old.changedDuringScan,
    );
    // 应用自己删除后索引更新可能滞后，仍保留变化提示供用户重新确认。
    changed = true;
    revision++;
  }
}

class LocalFileScanSnapshot {
  const LocalFileScanSnapshot({
    required this.entries,
    required this.directories,
    required this.roots,
    required this.indexStamp,
    this.unreadable = const {},
    this.changedDuringScan = false,
  });
  final List<LocalBookEntry> entries;
  final Map<String, LocalBookEntry> directories;
  final Set<String> roots;
  final String? indexStamp;
  final Set<String> unreadable;
  final bool changedDuringScan;
}

bool _under(String path, String directory) =>
    path == directory || path.startsWith('$directory/');

/// 扫描只生成候选结果，由仍然有效的页面请求决定是否发布。
Future<LocalFileScanSnapshot?> scanLocalFiles(
  LocalBookFiles files,
  Set<String> extensions,
  List<LocalBookEntry> roots, {
  LocalFileScanSnapshot? previous,
  required bool Function() cancelled,
  required void Function(int) onProgress,
}) async {
  final indexBefore = await files.indexStamp(extensions);
  final pending = [...roots];
  final directories = <String, LocalBookEntry>{};
  final found = <String, LocalBookEntry>{};
  final unreadable = <String>{};
  final rootPaths = roots.map((e) => e.path).toSet();
  // 拔出的卡和暂时不可读的目录不能被当成“里面的文件都被删除了”。
  unreadable.addAll(previous?.roots.difference(rootPaths) ?? {});
  // 记录拔出卡的原扫描范围，重复刷新时也继续保留，重新挂载后才能确认。
  rootPaths.addAll(previous?.roots ?? {});
  while (pending.isNotEmpty) {
    if (cancelled()) return null;
    final directory = pending.removeLast();
    if (directories.containsKey(directory.path)) continue;
    directories[directory.path] = directory;
    try {
      final children = await files.list(
        directory.path,
        counts: false,
        extensions: extensions,
      );
      for (final child in children) {
        if (child.directory) {
          pending.add(child);
        } else if (extensions.contains(child.extension)) {
          found[child.path] = child;
        }
      }
    } catch (_) {
      unreadable.add(directory.path);
    }
    if (directories.length % 20 == 0) onProgress(directories.length);
  }
  if (cancelled()) return null;
  if (!await files.hasAccess()) throw StateError('文件访问权限已关闭');
  if (cancelled()) return null;
  if (previous != null) {
    for (final old in previous.entries) {
      if (unreadable.any((dir) => _under(old.path, dir))) {
        found.putIfAbsent(old.path, () => old);
      }
    }
    for (final old in previous.directories.entries) {
      if (unreadable.any((dir) => _under(old.key, dir))) {
        directories.putIfAbsent(old.key, () => old.value);
      }
    }
  }
  // 对照扫描前取得的目录属性，发现扫描期间仍在写文件时提示再次刷新。
  var changed = false;
  final directoryList = directories.values.toList();
  for (var at = 0; at < directoryList.length; at += 256) {
    if (cancelled()) return null;
    final batch = directoryList.skip(at).take(256).toList();
    final checked = await files.inspect(batch.map((e) => e.path).toList());
    final now = {for (final e in checked.entries) e.path: e};
    for (final old in batch) {
      if (now[old.path]?.stamp != old.stamp) changed = true;
    }
    unreadable.addAll(checked.unavailable);
    unreadable.addAll(checked.missing);
  }
  final indexAfter = await files.indexStamp(extensions);
  if (indexBefore != null && indexAfter != null && indexBefore != indexAfter) {
    changed = true;
  }
  if (cancelled()) return null;
  return LocalFileScanSnapshot(
    entries: found.values.toList(),
    directories: directories,
    roots: rootPaths,
    indexStamp: indexBefore ?? indexAfter,
    unreadable: unreadable,
    changedDuringScan: changed,
  );
}

/// 系统索引和目录属性都是变化线索；不读取整本书，也不在每次进入时遍历全部文件。
Future<({bool changed, bool uncertain})> checkLocalFileChanges(
  LocalBookFiles files,
  Set<String> extensions,
  LocalFileScanSnapshot snapshot, {
  required bool Function() cancelled,
}) async {
  final roots = await files.roots();
  if (cancelled()) return (changed: false, uncertain: false);
  final rootPaths = roots.map((e) => e.path).toSet();
  if (rootPaths.length != snapshot.roots.length ||
      !rootPaths.containsAll(snapshot.roots)) {
    return (changed: true, uncertain: true);
  }
  final index = await files.indexStamp(extensions);
  if (cancelled()) return (changed: false, uncertain: false);
  if (index != null &&
      snapshot.indexStamp != null &&
      index != snapshot.indexStamp) {
    return (changed: true, uncertain: false);
  }
  var uncertain = snapshot.unreadable.isNotEmpty;
  final paths = snapshot.directories.keys.toList();
  final changedDirectories = <String>[];
  for (var at = 0; at < paths.length; at += 256) {
    if (cancelled()) return (changed: false, uncertain: false);
    final batch = paths.skip(at).take(256).toList();
    final checked = await files.inspect(batch);
    uncertain |= checked.unavailable.isNotEmpty;
    if (checked.missing.isNotEmpty) {
      return (changed: true, uncertain: uncertain);
    }
    for (final entry in checked.entries) {
      if (!entry.directory) return (changed: true, uncertain: uncertain);
      if (entry.stamp.isEmpty ||
          entry.stamp != snapshot.directories[entry.path]?.stamp) {
        changedDirectories.add(entry.path);
      }
    }
  }
  final oldFiles = {for (final e in snapshot.entries) e.path: e};
  final visited = <String>{};
  while (changedDirectories.isNotEmpty) {
    if (cancelled()) return (changed: false, uncertain: false);
    final path = changedDirectories.removeLast();
    if (!visited.add(path)) continue;
    try {
      final children = await files.list(
        path,
        counts: false,
        extensions: extensions,
      );
      final present = <String>{};
      for (final child in children) {
        if (child.directory) {
          if (!snapshot.directories.containsKey(child.path)) {
            changedDirectories.add(child.path);
          }
        } else if (extensions.contains(child.extension)) {
          present.add(child.path);
          final old = oldFiles[child.path];
          if (old == null ||
              old.size != child.size ||
              old.modified != child.modified ||
              old.stamp != child.stamp) {
            return (changed: true, uncertain: uncertain);
          }
        }
      }
      if (snapshot.entries.any(
        (e) =>
            e.path.substring(0, e.path.lastIndexOf('/')) == path &&
            !present.contains(e.path),
      )) {
        return (changed: true, uncertain: uncertain);
      }
    } catch (_) {
      uncertain = true;
    }
  }
  return (changed: false, uncertain: uncertain);
}
