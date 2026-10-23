import 'dart:async';
import 'dart:convert';
import 'dart:developer' show Timeline;
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'package:path/path.dart' as p;
import 'package:direct_read_rust/direct_read_rust.dart';
import 'package:direct_read_rust/original_html.dart';

import '../../core/diagnostics/reader_work_trace.dart';
import '../../core/diagnostics/original_processing.dart';

import '../../domain/models/book_document.dart';
import '../../domain/repositories/chapter_content_repository.dart';
import '../../engine/layout/english_hyphenation.dart';
import '../../engine/normalization/text_decoding.dart';
import '../../engine/parsers/epub/epub_archive.dart';
import '../../engine/parsers/epub/epub_sanitizer.dart';
import '../../engine/parsers/epub/epub_source_reader.dart';
import '../../engine/parsers/epub/xhtml_blocks.dart';
import 'book_source_path.dart';
import 'indexed_chapter_reader.dart';
import 'indexed_publication.dart';
import 'publication_cache.dart';

/// 一本原书共用一个后台 isolate。归档句柄和 DOM 都不进入界面线程，
/// 图片、字体及完整 HTML 用可转移字节返回；章节间继续复用归档和词典。
class EpubSourceWorker {
  final _responses = ReceivePort();
  final _pending = <int, Completer<Object?>>{};
  final _exited = Completer<void>();
  late final SendPort _commands;
  late final List<String> entries;
  int _nextId = 0;
  bool _ended = false;

  static Future<EpubSourceWorker> open({
    required String libraryRoot,
    required String cacheRoot,
    required String bookId,
    required int contentVersion,
    required List<Chapter> chapters,
    bool cacheDocuments = true,
    required Uint8List? dictionary,
  }) async {
    final worker = EpubSourceWorker();
    final ready = Completer<Object?>();
    worker._pending[0] = ready;
    worker._responses.listen(worker._receive);
    try {
      await Isolate.spawn(
        _run,
        (
          reply: worker._responses.sendPort,
          libraryRoot: libraryRoot,
          cacheRoot: cacheRoot,
          bookId: bookId,
          version: contentVersion,
          chapters: chapters,
          dictionary: dictionary,
          features: ProcessingFeatures.mask,
          originalMode: OriginalProcessing.mode,
          cacheEpoch: PublicationCache.processEpoch,
          cacheDocuments: cacheDocuments,
        ),
        onExit: worker._responses.sendPort,
        onError: worker._responses.sendPort,
        debugName: 'epub-source-$bookId',
      );
    } catch (error, stack) {
      worker._finish(error, stack);
    }
    final result = await ready.future as (SendPort, List<String>);
    worker._commands = result.$1;
    worker.entries = result.$2;
    return worker;
  }

  void _receive(Object? message) {
    if (message case (
      int id,
      Object? value,
      Object? error,
      StackTrace? stack,
    )) {
      final pending = _pending.remove(id);
      if (error != null) {
        pending?.completeError(error, stack);
      } else {
        pending?.complete(value);
      }
      return;
    }
    // 未捕获错误或提前退出也结束等待，避免 WebView 的资源请求一直挂起。
    _finish(StateError('原书后台任务已退出：${message ?? "会话结束"}'), StackTrace.current);
  }

  void _finish(Object error, StackTrace stack) {
    if (_ended) return;
    _ended = true;
    for (final pending in _pending.values) {
      pending.completeError(error, stack);
    }
    _pending.clear();
    _responses.close();
    _exited.complete();
  }

  Future<Object?> _request(String operation, [Object? entry]) async {
    if (_ended) return Future.error(StateError('原书后台任务已关闭'));
    final id = ++_nextId;
    final result = Completer<Object?>();
    _pending[id] = result;
    return traceReaderWork('original.request', () {
      _commands.send((
        id,
        operation,
        entry,
        readerWorkTraceEnabled ? Timeline.now : 0,
      ));
      return result.future;
    }, {'request': id, 'operation': operation, 'pending': _pending.length});
  }

  Future<({Uint8List bytes, String contentType})?> resource(
    String entry,
  ) async {
    final result = await _request('resource', entry);
    if (result == null) return null;
    final (data, type) = result as (TransferableTypedData, String);
    return (bytes: data.materialize().asUint8List(), contentType: type);
  }

  Future<String?> document(String entry) async =>
      await _request('document', entry) as String?;

  Future<Map<String, double?>?> tocPositions(
    String entry,
    List<String> fragments,
  ) async => (await _request('toc_positions', (entry, fragments)) as Map?)
      ?.cast<String, double?>();

  /// Small import metadata crosses the isolate once, instead of one round-trip
  /// per chapter. The worker verifies the source before returning it.
  Future<Map<String, Map<String, double?>>> tocIndex() async =>
      (await _request('toc_index') as Map).cast<String, Map<String, double?>>();

  Future<Map<String, Map<String, double>>> tocHeadingIndex() async =>
      (await _request('toc_headings') as Map)
          .cast<String, Map<String, double>>();

  Future<Map<String, dynamic>?> proof() async =>
      await _request('proof') as Map<String, dynamic>?;

  // 预取只需要后台落盘，不把暂时不会显示的完整章节再传回界面线程。
  Future<void> prefetch(String entry) async {
    await _request('prefetch', entry);
  }

  void resetBudget() {
    if (!_ended) _commands.send((-1, 'reset', null, 0));
  }

  /// 调用方先等资源落盘，再关闭句柄，并等待 isolate 真正退出。
  Future<void> close() async {
    if (!_ended) await _request('close');
    await _exited.future;
  }
}

typedef _Start = ({
  SendPort reply,
  String libraryRoot,
  String cacheRoot,
  String bookId,
  int version,
  List<Chapter> chapters,
  Uint8List? dictionary,
  int features,
  int originalMode,
  String cacheEpoch,
  bool cacheDocuments,
});

Future<void> _run(_Start start) async {
  ProcessingFeatures.configureExperiment(start.features);
  final commands = ReceivePort();
  EpubSourceReader? reader;
  IndexedChapterReader? sourceCheck;
  try {
    final bookDirectory = p.join(start.libraryRoot, start.bookId);
    final contentDirectory = p.join(
      bookDirectory,
      'content',
      '${start.version}',
    );
    final manifest = File(p.join(contentDirectory, 'manifest.json'));
    if (manifest.existsSync() &&
        (jsonDecode(manifest.readAsStringSync()) as Map)['sourceIndex'] !=
            null) {
      sourceCheck = IndexedChapterReader.open(
        bookDirectory,
        contentDirectory,
        cacheRoot: start.cacheRoot,
        cacheEpoch: start.cacheEpoch,
      );
      await sourceCheck.verifySource();
    }
    final mobi =
        sourceCheck?.index.format == 'mobi' ||
        sourceCheck?.index.format == 'azw3';
    reader = EpubSourceReader.open(
      mobi
          ? p.join(contentDirectory, 'publication')
          : bookSourcePath(p.join(start.libraryRoot, start.bookId), 'epub'),
      directory: mobi,
      digests: sourceCheck?.index.publication ?? const {},
      entryArchive: sourceCheck?.index.directMobi == true
          ? openIndexedPublication(
              sourceCheck!.source.path,
              contentDirectory,
              sourceCheck.index,
            )
          : null,
    );
    final mismatch = reader.mismatchWith(start.chapters);
    if (mismatch != null) {
      throw ContentFailure(
        ContentErrorCode.corrupted,
        '原书文件与章节索引不一致：$mismatch',
      );
    }
    final store = _Resources(
      reader,
      start,
      sourceCheck?.index.sourceDigest,
      sourceCheck?.cache,
      {
        for (final image
            in sourceCheck?.index.images.entries ??
                const <MapEntry<String, List<int>>>[])
          if (image.value[0] >= 0) image.key,
      },
    );
    start.reply.send((0, (commands.sendPort, store.entries), null, null));
    // 不同资源的磁盘 I/O 可并行；同步解压和 DOM 处理只占用本 isolate。
    // 同一条目由 _Resources 合并，close 由主线程等全部应答后才发送。
    commands.listen((dynamic message) async {
      final (id, operation, argument, sentUs) =
          message as (int, String, Object?, int);
      final entry = argument is String ? argument : null;
      final trace = operation == 'reset'
          ? null
          : ReaderWorkTrace.start('original.worker', {
              'request': id,
              'operation': operation,
              'queueUs': readerWorkTraceEnabled ? Timeline.now - sentUs : 0,
            });
      try {
        Object? result;
        // 已打开的原书会话也核对来源；命中网页/资源缓存不能绕过变更检测。
        if (operation == 'resource' ||
            operation == 'document' ||
            operation == 'toc_positions' ||
            operation == 'toc_index' ||
            operation == 'toc_headings' ||
            operation == 'prefetch' ||
            operation == 'proof') {
          await sourceCheck?.verifySource();
        }
        switch (operation) {
          case 'toc_headings':
            result =
                sourceCheck?.index.tocHeadings ??
                const <String, Map<String, double>>{};
          case 'toc_index':
            result =
                sourceCheck?.index.tocPositions ??
                const <String, Map<String, double?>>{};
          case 'proof':
            if (sourceCheck != null) {
              final stat = sourceCheck.verifiedStat!;
              result = <String, dynamic>{
                'scope':
                    '${store.sourceDigest}:${start.version}:${start.originalMode}:original1:${start.dictionary == null ? 'source' : sha256.convert(start.dictionary!).toString()}',
                'source': sourceCheck.source.path,
                'bytes': stat.size,
                'modifiedUs': stat.modified.microsecondsSinceEpoch,
                'changedUs': stat.changed.microsecondsSinceEpoch,
                'imported': contentDirectory,
                'cached': store.originalDirectory,
                if (store.cache != null)
                  'shared': p.join(store.cache!.directory, 'assets'),
                'types': reader!.nativeResourceTypes,
                'chapters': store.entries,
              };
            }
          case 'resource':
            final bytes = await store.load(entry!);
            if (bytes != null) {
              result = (
                TransferableTypedData.fromList([bytes]),
                store.typeOf(entry),
              );
            }
          case 'document':
            final bytes = await store.load(entry!);
            result = bytes == null ? null : decodeTextBytes(bytes);
          case 'toc_positions':
            final (name, fragments) = argument as (String, List<String>);
            final chapterId = start.chapters[store.entries.indexOf(name)].id;
            final prepared = sourceCheck?.index.tocPositions[chapterId];
            if (prepared != null && fragments.every(prepared.containsKey)) {
              result = {
                for (final fragment in fragments) fragment: prepared[fragment],
              };
              break;
            }
            final bytes = await store._load(name, textOnly: true);
            result = bytes == null
                ? null
                : XhtmlBlockBuilder.anchorPositions(
                    decodeTextBytes(bytes),
                    name,
                    fragments,
                  );
          case 'prefetch':
            await store.load(entry!);
          case 'reset':
            store.reader.resetBudget();
            return;
          case 'close':
            store.close();
            store.reader.close();
            await sourceCheck?.close();
            commands.close();
        }
        start.reply.send((id, result, null, null));
        trace?.finish();
      } catch (error, stack) {
        trace?.finish(status: error.runtimeType.toString());
        start.reply.send((id, null, error, stack));
      }
    });
  } catch (error, stack) {
    reader?.close();
    await sourceCheck?.close();
    commands.close();
    start.reply.send((0, null, error, stack));
  }
}

/// 原来的资源选择顺序和转换规则原样保留，只改变执行位置。
class _Resources {
  _Resources(
    this.reader,
    this.start,
    this.sourceDigest,
    this.cache,
    this.persistentImages,
  ) : entries = List.generate(reader.chapterCount, reader.entryPathAt);

  final EpubSourceReader reader;
  final _Start start;
  final String? sourceDigest;
  final PublicationCache? cache;
  final Set<String> persistentImages;
  final _activeEntries = <String>[];
  final _dependencies = <String, Set<String>>{};
  final List<String> entries;
  late final _chapters = entries.toSet();
  final _pending = <String, Future<Uint8List?>>{};
  NativeOriginalHtml? _native;
  void close() => _native?.close();

  String get originalDirectory => cache == null
      ? p.joinAll([
          start.cacheRoot,
          'original',
          start.bookId,
          '${start.version}',
          ?sourceDigest,
          start.dictionary == null ? 'source1' : 'hyphen1',
        ])
      : p.join(
          cache!.directory,
          'original',
          start.dictionary == null ? 'source1' : 'hyphen1',
        );

  File _cached(String entry) => File(
    cache != null && !_chapters.contains(entry)
        ? p.join(cache!.directory, 'assets', entry)
        : p.join(originalDirectory, entry),
  );

  String get _previousDirectory => p.joinAll([
    start.cacheRoot,
    'original',
    start.bookId,
    '${start.version}',
    ?sourceDigest,
    start.dictionary == null ? 'source1' : 'hyphen1',
  ]);

  void _track(String entry, Uint8List bytes) {
    final store = cache;
    if (store == null) return;
    _recordDependencies(entry, bytes);
    if (_chapters.contains(entry)) {
      _activeEntries.remove(entry);
      _activeEntries.add(entry);
      while (_activeEntries.length > 4) {
        _activeEntries.removeAt(0);
      }
    }
    final visited = <String>{}, pending = [..._activeEntries];
    while (pending.isNotEmpty) {
      final name = pending.removeLast();
      if (!visited.add(name)) continue;
      if (!_dependencies.containsKey(name) &&
          {'.html', '.xhtml', '.css', '.svg'}.contains(p.extension(name))) {
        final file = _cached(name);
        if (file.existsSync()) {
          _recordDependencies(name, file.readAsBytesSync());
        }
      }
      pending.addAll(_dependencies[name] ?? const <String>{});
    }
    store.pin('original', visited.map(_cached));
    store.trim();
  }

  void _recordDependencies(String entry, Uint8List bytes) {
    final references = <String>{};
    if ({'.html', '.xhtml', '.css', '.svg'}.contains(p.extension(entry))) {
      final text = decodeTextBytes(bytes);
      final values = <String>[];
      // Only displayed resources are dependencies. A TOC hyperlink must not
      // protect every chapter (and all their historical caches) in the book.
      final tags = RegExp(
        r'<\s*(?:img|image|use|link|source|video|audio|object)\b[^>]*>',
        caseSensitive: false,
      );
      final attributes = RegExp(
        r'''(?:src|href|poster|data)\s*=\s*(?:"([^"]*)"|'([^']*)')''',
        caseSensitive: false,
      );
      for (final tag in tags.allMatches(text)) {
        for (final attribute in attributes.allMatches(tag[0]!)) {
          values.add(attribute[1] ?? attribute[2]!);
        }
      }
      final css = RegExp(
        r'''url\(\s*(?:"([^"]*)"|'([^']*)'|([^\s)]+))\s*\)|@import\s+["']([^"']+)["']''',
        caseSensitive: false,
      );
      for (final match in css.allMatches(text)) {
        values.add(
          [for (var i = 1; i <= 4; i++) match[i]].whereType<String>().first,
        );
      }
      for (final value in values) {
        try {
          final path = resolveEntryPath(entry, value);
          if (path != null &&
              !_chapters.contains(path) &&
              reader.containsEntry(path)) {
            references.add(path);
          }
        } on FormatException {
          /* External/invalid URLs are not local files. */
        }
      }
    }
    _dependencies[entry] = references;
  }

  Future<Uint8List?> load(String entry) =>
      _pending[entry] ??= _loadProtected(entry).whenComplete(() {
        _pending.remove(entry);
      });

  Future<Uint8List?> _loadProtected(String entry) async {
    if (start.cacheDocuments) await cache?.beginPreparation();
    try {
      return await _load(entry);
    } finally {
      if (start.cacheDocuments) cache?.endPreparation();
    }
  }

  Future<Uint8List?> _load(String entry, {bool textOnly = false}) async {
    // 关闭诊断时不为日志查找章节号，避免每次加载图片都额外遍历目录。
    final trace = !readerWorkTraceEnabled
        ? null
        : ReaderWorkTrace.start('original.resource', {
            'chapter': entries.indexOf(entry),
            'type': typeOf(entry),
          });
    try {
      if (!reader.containsEntry(entry)) return null;
      if ((textOnly || !start.cacheDocuments) && _chapters.contains(entry)) {
        // TOC/listening metadata must not expand the entire book into HTML
        // caches. Reuse an existing display entry, but never publish/pin one.
        final cached = _cached(entry);
        try {
          if (cached.existsSync()) return cached.readAsBytesSync();
          final previous = File(p.join(_previousDirectory, entry));
          if (previous.existsSync()) return previous.readAsBytesSync();
        } on FileSystemException {
          /* Rebuild a reclaimed entry below. */
        }
        final bytes = reader.readEntry(entry);
        return bytes == null ? null : _transform(entry, bytes, trace);
      }
      final imported = File(
        p.join(
          start.libraryRoot,
          start.bookId,
          'content',
          '${start.version}',
          'res',
          entry,
        ),
      );
      final cached = _cached(entry);
      if (await imported.exists()) {
        try {
          if (cache != null &&
              !persistentImages.contains(entry) &&
              !_chapters.contains(entry)) {
            cache!.adopt(imported, cached);
          } else {
            trace?.details['hit'] = 'imported';
            return await imported.readAsBytes();
          }
        } on FileSystemException {
          // 简化会话可能同时把旧图片接到共享目录；继续从共享文件或原书读取。
        }
      }
      if (cache != null && !cached.existsSync()) {
        cache!.adopt(File(p.join(_previousDirectory, entry)), cached);
      }
      cache?.preparing(cached);
      if (await cached.exists()) {
        try {
          final bytes = await cached.readAsBytes();
          _track(entry, bytes);
          trace?.details['hit'] = 'disk';
          return bytes;
        } on FileSystemException {
          // 与原实现一致：读不到缓存时尝试从归档重新准备。
        }
      }
      trace?.mark('cache_lookup');
      trace?.details['hit'] = 'miss';
      final raw = reader.readEntry(entry);
      trace?.mark('zip_read');
      if (raw == null) return null;
      final bytes = _transform(entry, raw, trace);
      trace?.mark('decode_sanitize_hyphenate');
      trace?.details['bytes'] = bytes.length;
      if (bytes.length <= EpubArchive.maxEntryBytes) {
        try {
          if (cache != null) {
            cache!.write(cached, bytes);
          } else {
            await cached.parent.create(recursive: true);
            // 原生读取可与后台准备并行，只有完整写完的文件才能发布。
            final temporary = File('${cached.path}.pending');
            await temporary.writeAsBytes(bytes, flush: false);
            await temporary.rename(cached.path);
          }
        } on FileSystemException {
          // 写缓存失败不阻止当前资源返回。
        }
      }
      trace?.mark('cache_write');
      _track(entry, bytes);
      return bytes;
    } catch (error) {
      trace?.finish(status: error.runtimeType.toString());
      rethrow;
    } finally {
      trace?.finish();
    }
  }

  Uint8List _transform(String entry, Uint8List raw, ReaderWorkTrace? trace) {
    if (_chapters.contains(entry)) {
      if (start.originalMode != 0) {
        final transformer = _native ??= NativeOriginalHtml(start.dictionary);
        final result = transformer.transform(raw);
        if (trace != null) {
          trace.details['htmlMode'] = 'rust';
          trace.details['htmlStagesUs'] = transformer.stageTimesUs;
        }
        return result;
      }
      final clock = trace == null ? null : (Stopwatch()..start());
      final decoded = decodeTextBytes(raw);
      final decodedUs = clock?.elapsedMicroseconds ?? 0;
      final sanitized = EpubSanitizer.sanitize(decoded).html;
      final sanitizedUs = clock?.elapsedMicroseconds ?? 0;
      final dictionary = start.dictionary;
      if (dictionary != null) EnglishHyphenation.prepareFromBytes(dictionary);
      final displayed = dictionary == null
          ? sanitized
          : EnglishHyphenation.document(sanitized);
      final hyphenUs = clock?.elapsedMicroseconds ?? 0;
      final result = Uint8List.fromList(utf8.encode(displayed));
      if (trace != null) {
        trace.details['htmlMode'] = 'dart';
        trace.details['htmlStagesUs'] = [
          decodedUs,
          sanitizedUs - decodedUs,
          hyphenUs - sanitizedUs,
          clock!.elapsedMicroseconds - hyphenUs,
        ];
      }
      return result;
    }
    if (reader.fonts.algorithmOf(entry) != null) {
      return reader.fonts
          .deobfuscate(entry, raw, reader.uniqueIdentifier)
          .bytes;
    }
    return raw;
  }

  String typeOf(String entry) {
    if (_chapters.contains(entry)) return 'text/html; charset=utf-8';
    final declared = reader.mediaTypeOf(entry);
    return declared.startsWith('text/') ? '$declared; charset=utf-8' : declared;
  }
}
