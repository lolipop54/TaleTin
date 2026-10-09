import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import '../../domain/models/book_document.dart';
import '../../domain/models/book_search.dart';
import '../../engine/search/search_chapter.dart';
import 'search_query_worker.dart';

/// 直接读取一章；正文、规范化和位置映射都留在后台。
Future<List<({BookSearchHit hit, int at})>> searchFileChapter(
  String file,
  String title,
  String bookId,
  int version,
  String query,
  int offset,
  int limit,
  String cacheVersion,
) => _worker.search(
  file,
  title,
  bookId,
  version,
  query,
  offset,
  limit,
  cacheVersion,
);

final _worker = _ChapterWorker();

/// 连续查询复用后台线程和最近两章，避免每查一章都创建 Isolate。
/// 闲置 15 秒释放；缓存最多 50 万字符，不把整本书常驻内存。
class _ChapterWorker {
  Future<SendPort>? _port;
  Isolate? _isolate;
  Timer? _idle;
  int _active = 0;
  Future<SendPort> _start() async {
    final ready = ReceivePort();
    _isolate = await Isolate.spawn(_runChapterWorker, ready.sendPort);
    final port = await ready.first as SendPort;
    ready.close();
    return port;
  }

  Future<List<({BookSearchHit hit, int at})>> search(
    String file,
    String title,
    String bookId,
    int version,
    String query,
    int offset,
    int limit,
    String cacheVersion,
  ) async {
    _idle?.cancel();
    _active++;
    final reply = ReceivePort();
    try {
      final port = await (_port ??= _start());
      port.send([
        reply.sendPort,
        file,
        title,
        bookId,
        version,
        query,
        offset,
        limit,
        cacheVersion,
      ]);
      final result = await reply.first;
      if (result is String) throw StateError(result);
      return result as List<({BookSearchHit hit, int at})>;
    } finally {
      reply.close();
      if (--_active == 0) {
        _idle = Timer(const Duration(seconds: 15), () {
          _isolate?.kill(priority: Isolate.immediate);
          _isolate = null;
          _port = null;
        });
      }
    }
  }
}

void _runChapterWorker(SendPort ready) {
  final requests = ReceivePort();
  final cache = <String, SearchChapter>{};
  ready.send(requests.sendPort);
  requests.listen((message) {
    final args = message as List;
    final reply = args[0] as SendPort;
    try {
      final key = '${args[1]}:${args[8]}';
      final chapter =
          cache.remove(key) ??
          SearchChapter(
            ChapterContent.fromJson(
              (jsonDecode(File(args[1] as String).readAsStringSync()) as Map)
                  .cast<String, Object?>(),
            ),
          );
      cache[key] = chapter;
      while (cache.length > 2 ||
          cache.values.fold<int>(0, (n, c) => n + c.source.length) > 500000) {
        cache.remove(cache.keys.first);
      }
      reply.send(
        matchSearchChapter(
          chapter,
          args[2] as String,
          args[3] as String,
          args[4] as int,
          args[5] as String,
          args[6] as int,
          args[7] as int,
        ),
      );
    } catch (error) {
      reply.send(error.toString());
    }
  });
}
