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
import 'chapter_disk_cache.dart';
import 'chapter_manifest.dart';
import 'indexed_chapter_reader.dart';
import 'publication_cache.dart';

part 'pdf_content_worker.dart';

/// 整个正文仓库共用一个后台任务，串行处理 ZIP、TXT 和缓存文件。
/// 重复章请求由仓库合并；清缓存和换书库也排在正在读的章节之后。
class ChapterContentWorker {
  ChapterContentWorker._(this.preparation);
  final TextPreparationService? preparation;
  final _responses = ReceivePort();
  final _pending = <int, Completer<Object?>>{};
  final _exited = Completer<void>();
  late SendPort _commands;
  var _nextId = 0;
  var _ended = false;

  static Future<ChapterContentWorker> open({
    required String libraryRoot,
    String? cacheRoot,
    TextPreparationService? preparation,
  }) async {
    final worker = ChapterContentWorker._(preparation);
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
  }) async =>
      await _request('chapter', (bookId, chapter, textOnly)) as ChapterContent;

  Future<Object?> pdf(String operation, Object? argument) =>
      _request('pdf', (operation, argument));

  Future<void> invalidate([String? bookId]) async {
    await _request('invalidate', bookId);
  }

  Future<ChapterManifest?> manifest(String bookId, String directory) async =>
      await _request('manifest', (bookId, directory)) as ChapterManifest?;

  Future<ChapterContent?> cachedPreviousChapter(
    String bookId,
    Chapter chapter,
  ) async => await _request('previous', (bookId, chapter)) as ChapterContent?;

  Future<void> clearCache([String? bookId]) async {
    await _request('clear', bookId);
  }

  Future<void> close() async {
    if (!_ended) await _request('close');
    await _exited.future;
  }
}

Future<void> _run((SendPort, String, String?, int, String) start) async {
  final (reply, libraryRoot, cacheRoot, features, cacheEpoch) = start;
  ProcessingFeatures.configureExperiment(features);
  final commands = ReceivePort();
  final readers = <String, IndexedChapterReader>{};
  final memory = <String, ChapterContent>{};
  final pdfCache = _PdfContentCache(libraryRoot, cacheRoot, cacheEpoch);
  final cache = ChapterDiskCache(
    cacheRoot == null ? null : p.join(cacheRoot, 'chapters'),
  );
  reply.send((0, commands.sendPort, null, null));

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
        case 'chapter':
          final (bookId, chapter, textOnly) =
              argument as (String, Chapter, bool);
          trace?.details.addAll({
            'chapter': chapter.ordinal,
            'textOnly': textOnly,
          });
          final key = '$bookId/${p.dirname(chapter.contentPath)}';
          final reader =
              readers.remove(key) ??
              IndexedChapterReader.open(
                p.join(libraryRoot, bookId),
                p.join(libraryRoot, bookId, p.dirname(chapter.contentPath)),
                cacheRoot: cacheRoot,
                cacheEpoch: cacheEpoch,
              );
          readers[key] = reader;
          while (readers.length > 2) {
            await readers.remove(readers.keys.first)!.close();
          }
          trace?.mark('open_index');
          await reader.verifySource();
          trace?.mark('verify_source');
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
                try {
                  if (store == null) {
                    cache.write(cacheKey, content);
                  } else {
                    store.write(
                      store.file('chapters/$diskKey'),
                      content.encode(),
                    );
                  }
                } on FileSystemException {
                  trace?.details['cacheWriteFailed'] = true;
                }
                trace?.mark('cache_encode_write');
              }
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
            result = content;
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
