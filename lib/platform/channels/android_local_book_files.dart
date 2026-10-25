import 'package:flutter/services.dart';

import '../../domain/services/local_book_files.dart';

class AndroidLocalBookFiles implements LocalBookFiles {
  static const _channel = MethodChannel('gtreader/local_book_files');
  @override
  Future<bool> hasAccess() async =>
      await _channel.invokeMethod<bool>('access') ?? false;
  @override
  Future<bool> requestAccess() async =>
      await _channel.invokeMethod<bool>('requestAccess') ?? false;
  @override
  Future<List<LocalBookEntry>> roots() => _entries('roots');
  @override
  Future<List<LocalBookEntry>> list(
    String path, {
    bool counts = true,
    Set<String> extensions = const {'txt', 'epub', 'mobi', 'azw3', 'pdf'},
  }) => _entries('list', {
    'path': path,
    'counts': counts,
    'extensions': extensions.toList(),
  });
  @override
  Future<void> delete(String path) =>
      _channel.invokeMethod<void>('delete', {'path': path});

  @override
  Future<LocalFileInspection> inspect(List<String> paths) async {
    final result = await _channel.invokeMapMethod<String, Object?>('inspect', {
      'paths': paths,
    });
    if (result == null) throw StateError('无法核验文件');
    return LocalFileInspection(
      entries: (result['entries']! as List)
          .map((e) => _entry(e as Map))
          .toList(),
      missing: (result['missing']! as List).cast<String>().toSet(),
      unavailable: (result['unavailable']! as List).cast<String>().toSet(),
    );
  }

  @override
  Future<String?> indexStamp(Set<String> extensions) => _channel
      .invokeMethod<String>('indexStamp', {'extensions': extensions.toList()});

  Future<List<LocalBookEntry>> _entries(
    String method, [
    Map<String, Object>? args,
  ]) async {
    final rows =
        await _channel.invokeListMethod<Map<Object?, Object?>>(method, args) ??
        [];
    return rows.map(_entry).toList();
  }

  LocalBookEntry _entry(Map row) => LocalBookEntry(
    path: row['path']! as String,
    name: row['name']! as String,
    directory: row['directory']! as bool,
    size: row['size']! as int,
    modified: DateTime.fromMillisecondsSinceEpoch(row['modified']! as int),
    sortName: row['sortName']! as String,
    count: row['count']! as int,
    stamp: row['stamp'] as String? ?? '',
  );
}
