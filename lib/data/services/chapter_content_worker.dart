import 'dart:async';
import 'dart:convert';
import 'dart:developer' show Timeline;
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:direct_read_rust/direct_read_rust.dart';

import '../../core/diagnostics/reader_work_trace.dart';

import '../../domain/models/book_document.dart';
import '../../domain/models/source_content_index.dart';
import '../../domain/repositories/chapter_content_repository.dart';
import '../../domain/services/text_preparation.dart';
import '../../domain/services/txt_chapter_sections.dart';
import '../../engine/normalization/content_fingerprint.dart';
import 'chapter_disk_cache.dart';
import 'chapter_manifest.dart';
import 'indexed_chapter_reader.dart';
import 'publication_cache.dart';

part 'pdf_content_worker.dart';

typedef _LongTxtBody = ({
  ChapterContent content,
  String digest,
  int length,
  int blocks,
});
typedef _TxtCacheRoom = ({int chapters, int units, int blocks});

/// 共用后台任务负责索引核验、ZIP 和磁盘缓存，超长 TXT 正文单独解码。
/// 正文仓库合并重复请求，清缓存或换源时等待在途读取结束。
class ChapterContentWorker {
  ChapterContentWorker._(this.preparation, this._libraryRoot, this._cacheRoot);
  final TextPreparationService? preparation;
  final String _libraryRoot;
  final String? _cacheRoot;
  final _responses = ReceivePort();
  final _pending = <int, Completer<Object?>>{};
  final _exited = Completer<void>();
  late SendPort _commands;
  var _nextId = 0;
  var _ended = false;
  int _cacheEpoch = 0;
  static const _longTxtCacheUnits = 8 * 1024 * 1024;
  static const _longTxtCacheBlocks = 400000;
  final _recentLongTxt = <(String, String), _LongTxtBody>{};

  static Future<ChapterContentWorker> open({
    required String libraryRoot,
    String? cacheRoot,
    TextPreparationService? preparation,
  }) async {
    final worker = ChapterContentWorker._(preparation, libraryRoot, cacheRoot);
    final ready = Completer<Object?>();
    worker._pending[0] = ready;
    worker._responses.listen(worker._receive);
    try {
      await Isolate.spawn(
        _run,
        (
          worker._responses.sendPort,
          libraryRoot,
          cacheRoot,
          ProcessingFeatures.mask,
          PublicationCache.processEpoch,
        ),
        onError: worker._responses.sendPort,
        onExit: worker._responses.sendPort,
        debugName: 'chapter-content',
      );
    } catch (error, stack) {
      worker._finish(error, stack);
    }
    worker._commands = await ready.future as SendPort;
    return worker;
  }

  void _receive(dynamic message) {
    if (message case (
      'decode',
      SendPort reply,
      Uint8List bytes,
      String charset,
    )) {
      _decode(reply, bytes, charset);
      return;
    }
    if (message case (
      int id,
      Object? result,
      Object? error,
      StackTrace? stack,
    )) {
      final pending = _pending.remove(id);
      if (error == null) {
        pending?.complete(result);
      } else {
        pending?.completeError(error, stack);
      }
      return;
    }
    _finish(StateError('正文后台任务已退出：${message ?? "会话结束"}'), StackTrace.current);
  }

  Future<void> _decode(SendPort reply, Uint8List bytes, String charset) async {
    try {
      if (preparation == null) throw StateError('缺少 TXT 编码服务');
      reply.send((
        await preparation!.preview(bytes: bytes, charset: charset),
        null,
      ));
    } catch (error) {
      reply.send((null, '$error'));
    }
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

  Future<Object?> _request(String operation, [Object? argument]) async {
    if (_ended) return Future.error(StateError('正文后台任务已关闭'));
    final id = ++_nextId;
    final pending = Completer<Object?>();
    final trace = ReaderWorkTrace.start('content.request', {
      'request': id,
      'operation': operation,
      'pending': _pending.length,
    });
    _pending[id] = pending;
    _commands.send((
      id,
      operation,
      argument,
      readerWorkTraceEnabled ? Timeline.now : 0,
    ));
    try {
      final result = await pending.future;
      trace?.finish();
      return result;
    } catch (error) {
      trace?.finish(status: error.runtimeType.toString());
      rethrow;
    }
  }

  Future<ChapterContent> chapter(
    String bookId,
    Chapter chapter, {
    bool textOnly = false,
    bool prepareLayoutDigest = false,
  }) async {
    final epoch = _cacheEpoch;
    // 纯 TXT 的只读定位和阅读使用同一正文，均须由后台核验源文件。
    final key = (bookId, chapter.contentPath);
    final cached = _recentLongTxt[key];
    final (body, digest) = await _request('chapter', (
      bookId,
      chapter,
      textOnly,
      prepareLayoutDigest,
      cached?.digest,
    )) as (ChapterContent?, String?);
    final content =
        body ??
        (cached != null && digest == cached.digest
            ? cached.content
            : await _readLongTxt(_libraryRoot, bookId, chapter, digest!));
    if (digest != null) ContentFingerprint.remember(content, digest);
    if (!textOnly &&
        prepareLayoutDigest &&
        epoch == _cacheEpoch &&
        digest?.startsWith('txt-source-v') == true &&
        chapter.textLength <= _longTxtCacheUnits &&
        content.blocks.length <= _longTxtCacheBlocks) {
      // 常见往返只涉及两章；字数和段落数量一起限制驻留内存。
      _rememberLongTxt(key, (
        content: content,
        digest: digest!,
        length: chapter.textLength,
        blocks: content.blocks.length,
      ));
    }
    return content;
  }

  void _rememberLongTxt((String, String) key, _LongTxtBody body) {
    _recentLongTxt.remove(key);
    _recentLongTxt[key] = body;
    while (true) {
      final room = _txtCacheRoom(_recentLongTxt.values);
      if (room.chapters >= 0 && room.units >= 0 && room.blocks >= 0) return;
      _recentLongTxt.remove(_recentLongTxt.keys.first);
    }
  }

  static _TxtCacheRoom _txtCacheRoom(Iterable<_LongTxtBody> entries) {
    var chapters = 2, units = _longTxtCacheUnits, blocks = _longTxtCacheBlocks;
    for (final entry in entries) {
      chapters--;
      units -= entry.length;
      blocks -= entry.blocks;
    }
    return (chapters: chapters, units: units, blocks: blocks);
  }

  Future<Map<String, List<TxtTocSection>>> txtTocSections(
    String bookId,
    String directory,
    SourceContentIndex index,
    List<Chapter> chapters,
  ) => _scanTxtSections((
    p.join(_libraryRoot, bookId),
    directory,
    _cacheRoot,
    PublicationCache.processEpoch,
    index,
    chapters,
  ));

  Future<(String, List<TxtSectionStart>)?> txtChapterPlan(
    String bookId,
    Chapter chapter,
  ) async =>
      await _request('txt-plan', (bookId, chapter))
          as (String, List<TxtSectionStart>)?;

  Future<ChapterContent> txtSection(
    String bookId,
    Chapter chapter,
    String identity,
    List<TxtSectionStart> starts,
    int section,
  ) async => await _request('txt-section', (
    bookId,
    chapter,
    identity,
    starts,
    section,
  )) as ChapterContent;

  Future<Object?> pdf(String operation, Object? argument) =>
      _request('pdf', (operation, argument));

  Future<void> invalidate([String? bookId]) async {
    _discardRecentTxt(bookId);
    await _request('invalidate', bookId);
  }

  void _discardRecentTxt(String? bookId) {
    _cacheEpoch++;
    _recentLongTxt.removeWhere((key, _) => bookId == null || key.$1 == bookId);
  }

  Future<ChapterManifest?> manifest(String bookId, String directory) async =>
      await _request('manifest', (bookId, directory)) as ChapterManifest?;

  Future<ChapterContent?> cachedPreviousChapter(
    String bookId,
    Chapter chapter,
  ) async => await _request('previous', (bookId, chapter)) as ChapterContent?;

  Future<void> clearCache([String? bookId]) async {
    _discardRecentTxt(bookId);
    await _request('clear', bookId);
  }

  Future<void> close() async {
    _discardRecentTxt(null);
    if (!_ended) await _request('close');
    await _exited.future;
  }
}

String _longTxtDigest(IndexedChapterReader reader, Chapter chapter) =>
    'txt-source-v$kContentVersion:${reader.signature}:${chapter.id}';

Future<Map<String, List<TxtTocSection>>> _scanTxtSections(
  (String, String, String?, String, SourceContentIndex, List<Chapter>) input,
) => Isolate.run(() async {
  final (bookDirectory, directory, cacheRoot, cacheEpoch, index, chapters) =
      input;
  final reader = IndexedChapterReader.open(
    bookDirectory,
    directory,
    cacheRoot: cacheRoot,
    cacheEpoch: cacheEpoch,
    preparedIndex: (kContentVersion, index),
  );
  try {
    return {
      for (final chapter in chapters)
        chapter.id: IndexedChapterReader.txtTocOfStarts(
          await reader.loadTxtSectionStarts(chapter),
        ),
    };
  } finally {
    await reader.close();
  }
});

// 一次性后台任务退出时可以转交整个正文对象，避免复制几十万个段落与行内文字对象。
Future<ChapterContent> _readLongTxt(
  String libraryRoot,
  String bookId,
  Chapter chapter,
  String digest,
) => Isolate.run(
  () => traceReaderWork('content.long_txt_read', () async {
    IndexedChapterReader? reader;
    try {
      final bookDirectory = p.join(libraryRoot, bookId);
      reader = IndexedChapterReader.open(
        bookDirectory,
        p.join(bookDirectory, p.dirname(chapter.contentPath)),
      );
      if (reader.index.format != 'txt' ||
          _longTxtDigest(reader, chapter) != digest) {
        throw const ContentFailure(
          ContentErrorCode.sourceChanged,
          '正文索引在读取期间改变',
        );
      }
      await reader.verifySource();
      return await reader.readTxt(chapter);
    } on ContentFailure {
      rethrow;
    } catch (error) {
      throw ContentFailure(ContentErrorCode.corrupted, '$error');
    } finally {
      await reader?.close();
    }
  }, {'chapter': chapter.ordinal}),
);

Future<void> _run((SendPort, String, String?, int, String) start) async {
  final (reply, libraryRoot, cacheRoot, features, cacheEpoch) = start;
  ProcessingFeatures.configureExperiment(features);
  final commands = ReceivePort();
  final readers = <String, IndexedChapterReader>{};
  final memory = <String, ChapterContent>{};
  final layoutDigests = Expando<String>();
  final pdfCache = _PdfContentCache(libraryRoot, cacheRoot, cacheEpoch);
  final cache = ChapterDiskCache(
    cacheRoot == null ? null : p.join(cacheRoot, 'chapters'),
  );
  reply.send((0, commands.sendPort, null, null));

  Future<IndexedChapterReader> readerFor(String bookId, Chapter chapter) async {
    final directory = p.dirname(chapter.contentPath);
    final key = '$bookId/$directory';
    final bookDirectory = p.join(libraryRoot, bookId);
    final reader =
        readers.remove(key) ??
        IndexedChapterReader.open(
          bookDirectory,
          p.join(bookDirectory, directory),
          cacheRoot: cacheRoot,
          cacheEpoch: cacheEpoch,
        );
    readers[key] = reader;
    while (readers.length > 2) {
      await readers.remove(readers.keys.first)!.close();
    }
    return reader;
  }

  Future<void> invalidate(String? bookId) async {
    await pdfCache.close(bookId);
    for (final key in readers.keys.toList()) {
      if (bookId == null || key.startsWith('$bookId/')) {
        await readers.remove(key)!.close();
      }
    }
    memory.removeWhere(
      (key, _) => bookId == null || key.startsWith('$bookId/'),
    );
  }

  Future<String> decode(Uint8List bytes, String charset) async {
    final response = ReceivePort();
    try {
      reply.send(('decode', response.sendPort, bytes, charset));
      final (text, error) = await response.first as (String?, String?);
      if (error != null) throw FormatException(error);
      return text!;
    } finally {
      response.close();
    }
  }

  await for (final message in commands) {
    final (id, operation, argument, sentUs) =
        message as (int, String, Object?, int);
    final trace = ReaderWorkTrace.start('content.worker', {
      'request': id,
      'operation': operation,
      'queueUs': readerWorkTraceEnabled ? Timeline.now - sentUs : 0,
    });
    try {
      Object? result;
      switch (operation) {
        case 'pdf':
          result = await pdfCache.run(argument as (String, Object?));
        case 'manifest':
          final (bookId, directory) = argument as (String, String);
          final file = File(
            p.join(libraryRoot, bookId, directory, 'manifest.json'),
          );
          Map<String, dynamic>? manifest;
          SourceContentIndex? index;
          if (file.existsSync()) {
            final decoded = jsonDecode(file.readAsStringSync());
            if (decoded is Map) {
              manifest = decoded.cast<String, dynamic>();
              if (manifest['sourceIndex'] case final Map raw) {
                index = SourceContentIndex.fromJson(
                  raw.cast<String, dynamic>(),
                );
                // 清单、索引和缓存身份在同一后台只解析一次，界面接收结果副本。
                // 原书/旧目录可以只读清单；版本不符仍由实际读章按原规则拒绝。
                if (manifest['contentVersion'] == kContentVersion) {
                  final key = '$bookId/$directory';
                  final reader =
                      readers.remove(key) ??
                      IndexedChapterReader.open(
                        p.join(libraryRoot, bookId),
                        p.join(libraryRoot, bookId, directory),
                        cacheRoot: cacheRoot,
                        cacheEpoch: cacheEpoch,
                        preparedIndex: (kContentVersion, index),
                      );
                  readers[key] = reader;
                  while (readers.length > 2) {
                    await readers.remove(readers.keys.first)!.close();
                  }
                }
              }
            }
          }
          if (manifest != null) {
            // 当前目录无需旧书修复：章信息已从数据库读好，不能再复制和构造一遍。
            // 索引单独传已解析对象，避免原始JSON结构与转换结果同时跨isolate复制。
            if (((manifest['tocRevision'] as num?)?.toInt() ?? 0) >=
                kTocRevision) {
              manifest.remove('chapters');
              manifest.remove('sourceIndex');
            }
            result = ChapterManifest(manifest, index);
          }
        case 'previous':
          final (bookId, chapter) = argument as (String, Chapter);
          final directory = p.dirname(chapter.contentPath);
          final reader =
              readers['$bookId/$directory'] ??
              IndexedChapterReader.open(
                p.join(libraryRoot, bookId),
                p.join(libraryRoot, bookId, directory),
                cacheRoot: cacheRoot,
                cacheEpoch: cacheEpoch,
              );
          final key = '$bookId/${reader.signature}/${chapter.id}.json';
          result =
              memory[key] ??
              (reader.cache == null
                  ? cache.read(key, chapter)
                  : ChapterDiskCache(
                      p.join(reader.cache!.directory, 'chapters'),
                    ).read('${chapter.id}.json', chapter)) ??
              cache.read(key, chapter);
          if (!readers.containsValue(reader)) await reader.close();
        case 'txt-plan':
          final (bookId, chapter) = argument as (String, Chapter);
          final reader = await readerFor(bookId, chapter);
          if (reader.index.format != 'txt') break;
          final starts = await reader.loadTxtSectionStarts(chapter);
          if (starts.length > 1) result = (reader.signature, starts);
        case 'txt-section':
          final (bookId, chapter, identity, starts, section) =
              argument as (String, Chapter, String, List<TxtSectionStart>, int);
          final reader = await readerFor(bookId, chapter);
          if (identity != reader.signature) {
            throw const ContentFailure(
              ContentErrorCode.sourceChanged,
              '正文索引在读取期间改变',
            );
          }
          final content = await reader.readTxtSection(chapter, starts, section);
          trace?.details.addAll({
            'chapter': chapter.ordinal,
            'section': section,
            'paragraphs': content.blocks.length,
          });
          result = content;
        case 'chapter':
          final (bookId, chapter, textOnly, prepareLayoutDigest, knownDigest) =
              argument as (String, Chapter, bool, bool, String?);
          trace?.details.addAll({
            'chapter': chapter.ordinal,
            'textOnly': textOnly,
          });
          final reader = await readerFor(bookId, chapter);
          trace?.mark('open_index');
          await reader.verifySource();
          trace?.mark('verify_source');
          if (reader.index.format == 'txt' &&
              chapter.textLength >= kLongTxtChapterLength) {
            // 原字节经核验后可直接解码。超长章读写整份 JSON 比从源文件读更重，
            // 排版也只需已核验的来源摘要、字节范围和转换版本来区分新旧正文。
            final digest = _longTxtDigest(reader, chapter);
            trace?.details['hit'] = knownDigest == digest
                ? 'recent-txt'
                : 'read-long-txt';
            result = (null, digest);
            break;
          }
          final cacheKey = '$bookId/${reader.signature}/${chapter.id}.json';
          final store = reader.cache;
          if (!textOnly) await store?.beginPreparation();
          try {
            final disk = store == null
                ? cache
                : ChapterDiskCache(p.join(store.directory, 'chapters'));
            final diskKey = store == null ? cacheKey : '${chapter.id}.json';
            var content = textOnly ? memory[cacheKey] : memory.remove(cacheKey);
            var hit = content == null ? 'miss' : 'memory';
            Uint8List? encoded;
            if (content == null) {
              content = disk.read(diskKey, chapter);
              if (content != null) hit = 'disk';
            }
            if (content == null && store != null && cacheRoot != null) {
              content = cache.read(cacheKey, chapter);
              if (content != null) {
                hit = 'previous-disk';
                store.adopt(
                  File(p.join(cacheRoot, 'chapters', cacheKey)),
                  store.file('chapters/$diskKey'),
                );
              }
            }
            trace?.mark('cache_read');
            trace?.details['hit'] = hit;
            if (content == null) {
              content = await reader.read(chapter, decode, textOnly: textOnly);
              trace?.mark('read_decode_convert');
              if (!textOnly) {
                // 缓存写失败不影响已正确解析的正文，磁盘紧张时仍能阅读。
                encoded =
                    store != null || cacheRoot != null || prepareLayoutDigest
                    ? content.encode()
                    : null;
                trace?.mark('cache_encode');
                try {
                  if (store != null) {
                    store.write(store.file('chapters/$diskKey'), encoded!);
                  } else if (encoded != null) {
                    cache.writeBytes(cacheKey, encoded);
                  }
                } on FileSystemException {
                  trace?.details['cacheWriteFailed'] = true;
                }
                trace?.mark('cache_write');
              }
            }
            String? layoutDigest;
            if (prepareLayoutDigest) {
              // 新章复用缓存写入的规范字节；磁盘命中也在当前后台任务内计算，
              // 不等整章传回界面后再把它复制给另一个 isolate。
              layoutDigest = layoutDigests[content] ??=
                  ContentFingerprint.digestBytes(encoded ?? content.encode());
              trace?.mark('layout_digest');
            }
            if (!textOnly) await reader.prepareResources(content);
            if (!textOnly && content.textLength <= 500000) {
              memory[cacheKey] = content;
              while (memory.length > 4 ||
                  memory.values.fold<int>(0, (n, c) => n + c.textLength) >
                      500000) {
                memory.remove(memory.keys.first);
              }
            }
            result = (content, layoutDigest);
            trace?.details['characters'] = content.textLength;
          } finally {
            if (!textOnly) store?.endPreparation();
          }
        case 'invalidate':
          await invalidate(argument as String?);
        case 'clear':
          await invalidate(argument as String?);
          cache.clear(argument);
          PublicationCache.clearChapters(
            PublicationCache.effectiveRoot(libraryRoot, cacheRoot),
            argument,
          );
        case 'close':
          await invalidate(null);
          commands.close();
      }
      reply.send((id, result, null, null));
      trace?.finish();
    } catch (error, stack) {
      trace?.finish(status: error.runtimeType.toString());
      reply.send((
        id,
        null,
        error is ContentFailure || operation == 'manifest'
            ? error
            : ContentFailure(ContentErrorCode.corrupted, '$error'),
        stack,
      ));
    }
  }
}
