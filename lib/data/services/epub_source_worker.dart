import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../../domain/models/book_document.dart';
import '../../domain/repositories/chapter_content_repository.dart';
import '../../engine/layout/english_hyphenation.dart';
import '../../engine/normalization/text_decoding.dart';
import '../../engine/parsers/epub/epub_archive.dart';
import '../../engine/parsers/epub/epub_sanitizer.dart';
import '../../engine/parsers/epub/epub_source_reader.dart';
import 'book_source_path.dart';

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

  Future<Object?> _request(String operation, [String? entry]) {
    if (_ended) return Future.error(StateError('原书后台任务已关闭'));
    final id = ++_nextId;
    final result = Completer<Object?>();
    _pending[id] = result;
    _commands.send((id, operation, entry));
    return result.future;
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

  // 预取只需要后台落盘，不把暂时不会显示的完整章节再传回界面线程。
  Future<void> prefetch(String entry) async {
    await _request('prefetch', entry);
  }

  void resetBudget() {
    if (!_ended) _commands.send((-1, 'reset', null));
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
});

void _run(_Start start) {
  final commands = ReceivePort();
  EpubSourceReader? reader;
  try {
    reader = EpubSourceReader.open(
      bookSourcePath(p.join(start.libraryRoot, start.bookId), 'epub'),
    );
    final mismatch = reader.mismatchWith(start.chapters);
    if (mismatch != null) {
      throw ContentFailure(
        ContentErrorCode.corrupted,
        '原书文件与章节索引不一致：$mismatch',
      );
    }
    final store = _Resources(reader, start);
    start.reply.send((0, (commands.sendPort, store.entries), null, null));
    // 不同资源的磁盘 I/O 可并行；同步解压和 DOM 处理只占用本 isolate。
    // 同一条目由 _Resources 合并，close 由主线程等全部应答后才发送。
    commands.listen((dynamic message) async {
      final (id, operation, entry) = message as (int, String, String?);
      try {
        Object? result;
        switch (operation) {
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
          case 'prefetch':
            await store.load(entry!);
          case 'reset':
            store.reader.resetBudget();
            return;
          case 'close':
            store.reader.close();
            commands.close();
        }
        start.reply.send((id, result, null, null));
      } catch (error, stack) {
        start.reply.send((id, null, error, stack));
      }
    });
  } catch (error, stack) {
    reader?.close();
    commands.close();
    start.reply.send((0, null, error, stack));
  }
}

/// 原来的资源选择顺序和转换规则原样保留，只改变执行位置。
class _Resources {
  _Resources(this.reader, this.start)
    : entries = List.generate(reader.chapterCount, reader.entryPathAt);

  final EpubSourceReader reader;
  final _Start start;
  final List<String> entries;
  late final _chapters = entries.toSet();
  final _pending = <String, Future<Uint8List?>>{};

  Future<Uint8List?> load(String entry) =>
      _pending[entry] ??= _load(entry).whenComplete(() {
        _pending.remove(entry);
      });

  Future<Uint8List?> _load(String entry) async {
    if (!reader.containsEntry(entry)) return null;
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
    if (await imported.exists()) return imported.readAsBytes();
    final cached = File(
      p.join(
        start.cacheRoot,
        'original',
        start.bookId,
        '${start.version}',
        start.dictionary == null ? 'source1' : 'hyphen1',
        entry,
      ),
    );
    if (await cached.exists()) {
      try {
        return await cached.readAsBytes();
      } on FileSystemException {
        // 与原实现一致：读不到缓存时尝试从归档重新准备。
      }
    }
    final raw = reader.readEntry(entry);
    if (raw == null) return null;
    final bytes = _transform(entry, raw);
    if (bytes.length <= EpubArchive.maxEntryBytes) {
      try {
        await cached.parent.create(recursive: true);
        await cached.writeAsBytes(bytes, flush: false);
      } on FileSystemException {
        // 写缓存失败不阻止当前资源返回。
      }
    }
    return bytes;
  }

  Uint8List _transform(String entry, Uint8List raw) {
    if (_chapters.contains(entry)) {
      final sanitized = EpubSanitizer.sanitize(decodeTextBytes(raw)).html;
      final dictionary = start.dictionary;
      if (dictionary != null) EnglishHyphenation.prepareFromBytes(dictionary);
      return Uint8List.fromList(
        utf8.encode(
          dictionary == null
              ? sanitized
              : EnglishHyphenation.document(sanitized),
        ),
      );
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
