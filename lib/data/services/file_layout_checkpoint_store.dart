import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../../domain/models/book_document.dart';
import '../../domain/services/layout_checkpoint_store.dart';
import '../../engine/normalization/content_fingerprint.dart';
import '../../core/diagnostics/reader_work_trace.dart';

/// 源内容摘要、实际字体文件摘要与精确布局参数共同决定可重建文件身份。
class FileLayoutCheckpointStore implements LayoutCheckpointStore {
  FileLayoutCheckpointStore(
    this.root, {
    required this.fontFingerprint,
    this.engineFingerprint = const String.fromEnvironment(
      'FLUTTER_ENGINE_REVISION',
    ),
  });
  final String root;
  final Future<String?> Function(String?) fontFingerprint;
  final String engineFingerprint;
  Future<void> _writes = Future.value();
  int _writeGeneration = 0;
  final _updates = <(String, int), Map<String, Object?>>{};
  final _queued = <(String, int), Future<void>>{};
  final _readers = <Future<void>>{};
  final _invalidReads = <String>{};
  Future<void>? _deleting;

  /// 退出测试/清理文件前等待已接受的写入，避免删完目录又被迟到写入重建。
  Future<void> get pendingWrites => _writes;
  static const maxFileBytes = 16 * 1024 * 1024;
  static const maxTotalBytes = 128 * 1024 * 1024;

  @override
  Future<String?> identity({
    required String bookId,
    required String title,
    required ChapterContent content,
    required String layout,
    required String? fontFamily,
  }) async {
    final font = await traceReaderWork(
      'layout.font_identity',
      () => fontFingerprint(fontFamily),
    );
    // 无法确认真实字体时照常阅读，仅放弃跨进程测量复用。
    if (font == null || engineFingerprint.isEmpty) return null;
    final digest = await ContentFingerprint.of(content);
    return sha256
        .convert(
          utf8.encode(
            jsonEncode([
              'measured-prefix-3',
              bookId,
              title,
              digest,
              layout,
              font,
              engineFingerprint,
              Platform.operatingSystemVersion,
              Platform.version,
              Platform.localeName,
            ]),
          ),
        )
        .toString();
  }

  String _path(String book, String key) =>
      p.join(root, sha256.convert(utf8.encode(book)).toString(), key);

  // 发布清单不删除旧分段；删除时短暂挡住新读取，并等已读取的清单用完其分段。
  // 字体测量和页面显示不等后台写入，只有清理文件需要此互斥。
  Future<void> _deleteExclusively(Future<void> Function() action) async {
    final done = Completer<void>();
    _deleting = done.future;
    try {
      await Future.wait(_readers.toList());
      await action();
    } finally {
      _deleting = null;
      done.complete();
    }
  }

  @override
  Future<void> clear([String? bookId]) {
    ++_writeGeneration;
    final target = bookId == null ? root : p.dirname(_path(bookId, 'unused'));
    final next = _writes.then(
      (_) => _deleteExclusively(() async {
        final directory = Directory(target);
        if (await directory.exists()) await directory.delete(recursive: true);
      }),
    );
    _writes = next.catchError((Object error) {});
    return next;
  }

  @override
  Future<Map<String, dynamic>?> read(
    String bookId,
    String identity, {
    int? throughCursor,
    int afterBlocks = 0,
  }) async {
    final path = _path(bookId, identity);
    final generation = _writeGeneration;
    while (_deleting != null) {
      await _deleting;
    }
    final done = Completer<void>();
    _readers.add(done.future);
    try {
      final result = await _readFile(path, throughCursor, afterBlocks);
      if (result == null) _invalidReads.add(path);
      return generation == _writeGeneration ? result : null;
    } finally {
      _readers.remove(done.future);
      done.complete();
    }
  }

  @override
  Future<void> write(
    String bookId,
    String identity,
    Map<String, Object?> checkpoint,
  ) {
    final path = _path(bookId, identity), directory = root;
    final job = (path, _writeGeneration);
    _updates[job] = checkpoint;
    // 同一恢复点尚未开始落盘时，只写最新前缀，不堆积大量过时全文副本。
    final queued = _queued[job];
    if (queued != null) return queued;
    final next = _writes.then((_) async {
      final latest = _updates.remove(job)!;
      _queued.remove(job);
      await _writeFile(path, latest, repair: _invalidReads.remove(path));
      await _deleteExclusively(() => _prune(directory, path));
    });
    // 缓存写入失败不能破坏已可读页面或位置保存，也不能阻挡后续有效缓存。
    _writes = next.catchError((Object error) {});
    _queued[job] = _writes;
    return _writes;
  }

  // 静态函数只捕获可传输的数值数据，不能把含在途 Future 的仓库实例带进 isolate。
  static Future<void> _writeFile(
    String path,
    Map<String, Object?> latest, {
    bool repair = false,
  }) => Isolate.run(() {
    final blocks = latest['blocks'] as List;
    final parts = <Map<String, Object?>>[];
    var total = 0;
    final directory = Directory(path)..createSync(recursive: true);
    if (!repair) {
      try {
        // 部分恢复不能把磁盘上更长的有效前缀覆盖成短前缀。
        final previous = _manifest(path);
        if ((previous['metadata'] as Map)['cursor'] >= latest['cursor']) return;
      } on Object {
        /* 首次建立或坏清单，重新发布。 */
      }
    }
    for (var from = 0; from < blocks.length;) {
      var end = (from + 64).clamp(0, blocks.length);
      // 表格一次整体测量；不能把恢复点留在同一张表格的中间。
      while (end < blocks.length &&
          (blocks[end - 1] as Map).containsKey('sourceCursor') &&
          blocks[end - 1]['sourceCursor'] == null) {
        end++;
      }
      final bytes = utf8.encode(jsonEncode(blocks.sublist(from, end)));
      total += bytes.length;
      if (total > maxFileBytes) return;
      final digest = sha256.convert(bytes).toString();
      final file = File(p.join(path, '$digest.segment.gz'));
      // 已封口的64块分段不改写；增长中的最后一段按新摘要另存。
      if (repair || !file.existsSync()) {
        final temporary = File('${file.path}.pending');
        temporary.writeAsBytesSync(gzip.encode(bytes), flush: true);
        temporary.renameSync(file.path);
      }
      parts.add({
        'sha256': digest,
        'bytes': bytes.length,
        'count': end - from,
        'cursor': end == blocks.length
            ? latest['cursor']
            : (blocks[end - 1]['sourceCursor'] ?? end),
      });
      from = end;
    }
    final metadata = Map<String, Object?>.of(latest)..remove('blocks');
    final payload = jsonEncode({
      'version': 3,
      'metadata': metadata,
      'parts': parts,
      'bytes': total,
    });
    if (utf8.encode(payload).length > 256 * 1024) return;
    final temporary = File(p.join(directory.path, 'manifest.pending'));
    temporary.writeAsStringSync(
      jsonEncode([sha256.convert(utf8.encode(payload)).toString(), payload]),
      flush: true,
    );
    // 全部分段落盘之后才一次替换清单；崩溃只留下不被引用的新段。
    temporary.renameSync(p.join(path, 'manifest.json'));
  });

  static Map<String, dynamic> _manifest(String path) {
    final file = File(p.join(path, 'manifest.json'));
    if (file.lengthSync() > 512 * 1024) throw const FormatException('清单过大');
    final envelope = jsonDecode(file.readAsStringSync()) as List;
    final payload = envelope[1] as String;
    if (sha256.convert(utf8.encode(payload)).toString() != envelope[0]) {
      throw const FormatException('清单摘要不一致');
    }
    final data = jsonDecode(payload) as Map<String, dynamic>;
    if (data['version'] != 3 || (data['bytes'] as int) > maxFileBytes) {
      throw const FormatException('缓存版本或预算不符');
    }
    return data;
  }

  static Future<Map<String, dynamic>?> _readFile(
    String path,
    int? throughCursor,
    int afterBlocks,
  ) => Isolate.run(() {
    final trace = ReaderWorkTrace.start('layout.checkpoint.read', {
      'throughCursor': throughCursor,
      'afterBlocks': afterBlocks,
    });
    try {
      final manifest = _manifest(path);
      final parts = manifest['parts'] as List;
      final blocks = <dynamic>[];
      var total = 0, skipped = 0, count = 0, cursor = 0, partIndex = 0;
      var selectedEnd = parts.length;
      if (throughCursor != null) {
        final targetPart = parts.indexWhere(
          (p) => (p['cursor'] as int) >= throughCursor,
        );
        if (targetPart >= 0) {
          selectedEnd = (targetPart + 2).clamp(0, parts.length);
        }
      }
      for (final part in parts.take(selectedEnd)) {
        partIndex++;
        cursor = part['cursor'] as int;
        final next = skipped + (part['count'] as int);
        if (next <= afterBlocks) {
          skipped = next;
          continue;
        }
        final digest = part['sha256'] as String;
        final size = part['bytes'] as int;
        if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(digest) ||
            size < 0 ||
            size > maxFileBytes ||
            total + size > maxFileBytes) {
          return null;
        }
        final file = File(p.join(path, '$digest.segment.gz'));
        if (file.lengthSync() > maxFileBytes) return null;
        final bytes = _CacheBytes(size);
        final decoder = gzip.decoder.startChunkedConversion(bytes);
        decoder.add(file.readAsBytesSync());
        decoder.close();
        final raw = bytes.take();
        if (raw.length != size || sha256.convert(raw).toString() != digest) {
          return null;
        }
        final rows = jsonDecode(utf8.decode(raw)) as List;
        if (rows.length != part['count']) return null;
        blocks.addAll(rows.skip((afterBlocks - skipped).clamp(0, rows.length)));
        skipped = next;
        count++;
        total += size;
      }
      if (throughCursor == null &&
          afterBlocks == 0 &&
          total != manifest['bytes']) {
        return null;
      }
      File(p.join(path, 'manifest.json')).setLastModifiedSync(DateTime.now());
      trace?.details.addAll({
        'parts': count,
        'totalParts': parts.length,
        'bytes': total,
        'blocks': blocks.length,
        'cursor': cursor,
      });
      return {
        ...manifest['metadata'] as Map<String, dynamic>,
        if (throughCursor != null || afterBlocks != 0) ...{
          'cursor': partIndex == 0
              ? (manifest['metadata'] as Map)['cursor']
              : cursor,
          '_from': afterBlocks,
          '_hasMore': selectedEnd < parts.length,
        },
        'blocks': blocks,
      };
    } on Object {
      return null;
    } finally {
      trace?.finish();
    }
  });

  static Future<void> _prune(String root, String current) => Isolate.run(() {
    final directory = Directory(root);
    if (!directory.existsSync()) return;
    final layouts = <(Directory, int, DateTime)>[];
    for (final book in directory.listSync().whereType<Directory>()) {
      for (final layout in book.listSync()) {
        if (layout is File) {
          layout.deleteSync();
          continue;
        } // 旧版可重建缓存。
        if (layout is! Directory) continue;
        try {
          final manifest = _manifest(layout.path);
          final keep = {
            'manifest.json',
            for (final part in manifest['parts'] as List)
              '${part['sha256']}.segment.gz',
          };
          var size = 0;
          for (final file in layout.listSync().whereType<File>()) {
            if (!keep.contains(p.basename(file.path))) {
              file.deleteSync();
            } else {
              size += file.lengthSync();
            }
          }
          layouts.add((
            layout,
            size,
            File(p.join(layout.path, 'manifest.json')).lastModifiedSync(),
          ));
        } on Object {
          layout.deleteSync(recursive: true);
        }
      }
    }
    layouts.sort((a, b) => a.$3.compareTo(b.$3));
    var total = layouts.fold<int>(0, (sum, item) => sum + item.$2);
    for (final item in layouts) {
      if (total <= maxTotalBytes) break;
      if (item.$1.path == current) continue;
      total -= item.$2;
      item.$1.deleteSync(recursive: true);
    }
  });
}

/// 限制解压输出，坏缓存不能先分配远超预算的内存再核对摘要。
class _CacheBytes extends ByteConversionSink {
  _CacheBytes(this.limit);
  final int limit;
  final _bytes = BytesBuilder(copy: false);
  @override
  void add(List<int> chunk) {
    if (_bytes.length + chunk.length > limit) {
      throw const FormatException('排版缓存超出预算');
    }
    _bytes.add(chunk);
  }

  @override
  void close() {}
  Uint8List take() => _bytes.takeBytes();
}
