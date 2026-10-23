import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../../core/diagnostics/reader_work_trace.dart';
import '../../domain/models/book_document.dart';
import '../../domain/models/locator.dart';
import '../../engine/parsers/epub/locator_dom_point.dart';

/// 仅保存章节位置资料；所有书共用128MiB，HTML/图片继续用原来的资源文件。
class OriginalPreparationCache {
  OriginalPreparationCache(this.root, {this.maxBytes = 128 * 1024 * 1024});
  final String root;
  final int maxBytes;
  static const maxEntryBytes = 16 * 1024 * 1024;
  Future<void> _flight = Future.value();
  int _generation = 0;
  int get generation => _generation;
  Future<void> get pending => _flight;
  String _directory(String book) =>
      p.join(root, sha256.convert(utf8.encode(book)).toString());
  String _path(String book, String key) => p.join(_directory(book), '$key.gz');
  Future<T> _serial<T>(Future<T> Function() action) {
    final next = _flight.then((_) => action());
    _flight = next.then<void>((_) {}, onError: (Object _) {});
    return next;
  }

  Future<LocatorDomMap?> read(
    String book,
    String key,
    String href,
    ChapterContent content,
    Locator identity,
  ) {
    final path = _path(book, key), generation = _generation;
    return _serial(() async {
      final result = await _readFile(path, key, href, content, identity);
      return generation == _generation ? result : null;
    });
  }

  static Future<LocatorDomMap?> _readFile(
    String path,
    String key,
    String href,
    ChapterContent content,
    Locator identity,
  ) => Isolate.run(() {
    final trace = ReaderWorkTrace.start('original.preparation.read');
    try {
      final file = File(path);
      if (!file.existsSync() || file.lengthSync() > maxEntryBytes) return null;
      final sink = _LimitedPreparationBytes(maxEntryBytes);
      final decoder = gzip.decoder.startChunkedConversion(sink);
      decoder.add(file.readAsBytesSync());
      decoder.close();
      final bytes = sink.take();
      final envelope = jsonDecode(utf8.decode(bytes)) as List;
      final payload = envelope[1] as String;
      if (sha256.convert(utf8.encode(payload)).toString() != envelope[0]) {
        return null;
      }
      final value = jsonDecode(payload) as Map<String, dynamic>;
      if (value['version'] != 1 || value['key'] != key) return null;
      final map = LocatorDomMap.fromPrepared(
        value['data'] as Map<String, dynamic>,
        href,
        content,
        identity,
      );
      map.progressMap; // 返回前在后台生成，不能回主线程再展开整章。
      file.setLastModifiedSync(DateTime.now());
      trace?.details.addAll({
        'hit': true,
        'bytes': file.lengthSync(),
        'rawBytes': bytes.length,
      });
      return map;
    } on Object {
      return null;
    } finally {
      trace?.finish();
    }
  });

  Future<void> write(
    String book,
    String key,
    Map<String, dynamic> data, {
    int? generation,
  }) {
    final path = _path(book, key), directory = root, budget = maxBytes;
    final acceptedGeneration = generation ?? _generation;
    return _serial(() async {
      if (acceptedGeneration != _generation) return;
      await _writeFile(path, directory, budget, key, data);
    });
  }

  static Future<void> _writeFile(
    String path,
    String directory,
    int budget,
    String key,
    Map<String, dynamic> data,
  ) => Isolate.run(() {
    final trace = ReaderWorkTrace.start('original.preparation.write');
    try {
      final payload = jsonEncode({'version': 1, 'key': key, 'data': data});
      final bytes = utf8.encode(
        jsonEncode([sha256.convert(utf8.encode(payload)).toString(), payload]),
      );
      if (bytes.length > maxEntryBytes) return;
      final compressed = gzip.encode(bytes);
      if (compressed.length > budget) return;
      final folder = Directory(directory)..createSync(recursive: true);
      final file = File(path);
      for (final abandoned
          in folder
              .listSync(recursive: true, followLinks: false)
              .whereType<File>()) {
        if (abandoned.path.endsWith('.pending')) abandoned.deleteSync();
      }
      // 在发布前回收旧资料，总量上限是整个目录，不是每本书各128MiB。
      final candidates =
          folder
              .listSync(recursive: true, followLinks: false)
              .whereType<File>()
              .where((f) => f.path.endsWith('.gz') && f.path != path)
              .toList()
            ..sort(
              (a, b) => a.lastModifiedSync().compareTo(b.lastModifiedSync()),
            );
      var total = candidates.fold<int>(0, (n, f) => n + f.lengthSync());
      for (final old in candidates) {
        if (total + compressed.length <= budget) break;
        total -= old.lengthSync();
        old.deleteSync();
      }
      file.parent.createSync(recursive: true);
      final temporary = File('$path.pending');
      temporary.writeAsBytesSync(compressed, flush: true);
      temporary.renameSync(path);
      trace?.details.addAll({
        'bytes': compressed.length,
        'poolBytes': total + compressed.length,
      });
    } on FileSystemException {
      // 磁盘满或用户清理缓存时，已解析的当前正文仍可正常显示。
    } finally {
      trace?.finish();
    }
  });

  Future<void> clear([String? book]) {
    ++_generation;
    final path = book == null ? root : _directory(book);
    return _serial(() async {
      final directory = Directory(path);
      if (await directory.exists()) await directory.delete(recursive: true);
    });
  }
}

class _LimitedPreparationBytes extends ByteConversionSink {
  _LimitedPreparationBytes(this.limit);
  final int limit;
  final _bytes = BytesBuilder(copy: false);
  int _length = 0;
  @override
  void add(List<int> bytes) {
    _length += bytes.length;
    if (_length > limit) throw const FormatException('章节准备缓存超出预算');
    _bytes.add(bytes);
  }

  @override
  void close() {}
  Uint8List take() => _bytes.takeBytes();
}
