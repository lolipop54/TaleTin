/// [ChapterContentRepository] 的文件实现。
///
/// 新书从来源索引按章读取，后台转换并缓存读过的章节；旧书仍兼容
/// 已保存的 JSON。两种路径使用相同正文规则，图片由界面按需解码。
library;

import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

import '../../core/diagnostics/reader_work_trace.dart';

import '../../domain/models/book_document.dart';
import '../../domain/repositories/chapter_content_repository.dart';
import '../../domain/services/text_preparation.dart';
import '../../engine/parsers/epub/epub_parser.dart';
import '../services/recover_txt_toc.dart';
import '../services/book_source_path.dart';
import '../services/enrich_epub_content.dart';
import '../services/toc_progress_cache.dart';
import '../services/chapter_content_worker.dart';
import '../../domain/services/toc_entry_index.dart';

Future<List<TocNode>> _recoverLegacyToc(
  String sourcePath,
  List<Chapter> chapters,
) => Isolate.run(() => EpubParser.resolveLegacyToc(sourcePath, chapters));

class FileChapterContentRepository implements ChapterContentRepository {
  FileChapterContentRepository({
    required this.libraryRoot,
    this.cacheCapacity = 4,
    this.textPreparation,
    this.cacheRoot,
  });

  /// `files/library` 绝对路径
  final String libraryRoot;
  final String? cacheRoot;
  Future<ChapterContentWorker>? _worker;
  final _storageModes = <String, Future<bool>>{};
  final _pendingChapters = <String, Future<ChapterContent>>{};
  final _migrations = <String, Future<void>>{};

  Future<ChapterContentWorker> _contentWorker() =>
      _worker ??= ChapterContentWorker.open(
        libraryRoot: libraryRoot,
        cacheRoot: cacheRoot,
        preparation: textPreparation,
      );

  /// 仅供更新前补充旧定位证据。只读旧版本的正文/缓存，不读取已改变的源文件。
  Future<ChapterContent?> cachedPreviousChapter(String bookId, Chapter chapter) async {
    final memory = _chapters['$bookId/${chapter.id}'];
    if (memory != null) return memory;
    if (await _indexed(bookId, chapter)) {
      return (await _contentWorker()).cachedPreviousChapter(bookId, chapter);
    }
    final file = File(chapterAbsolutePath(bookId, chapter));
    if (!await file.exists()) return null;
    return ChapterContent.fromJson((jsonDecode(await file.readAsString()) as Map).cast<String, Object?>());
  }

  Future<bool> _indexed(String bookId, Chapter chapter) {
    final directory = p.dirname(chapterAbsolutePath(bookId, chapter));
    return _storageModes.putIfAbsent(directory, () async {
      final file = File(p.join(directory, 'manifest.json'));
      if (!await file.exists()) return false;
      return (jsonDecode(await file.readAsString()) as Map)['sourceIndex'] !=
          null;
    });
  }

  /// 单章正文缓存条数：阅读器实际只需要当前章与预排的相邻章。
  final int cacheCapacity;
  final TextPreparationService? textPreparation;

  /// Dart 的 Map 字面量本身按插入顺序遍历，直接当 LRU 用
  final _chapters = <String, ChapterContent>{};
  final _pending = <String, Set<Future<void>>>{};
  final _changing = <String>{};
  bool _closed = false;
  String? _tocKey;
  List<TocNode>? _toc;
  final _pendingTocs = <String, Future<List<TocNode>>>{};

  @override
  Future<ChapterContent> chapter(
    String bookId,
    Chapter chapter, {
    bool textOnly = false,
  }) => traceReaderWork(
    'content.repository',
    () => _read(
      bookId,
      () => _pendingChapters.putIfAbsent(
        '$bookId/${chapter.contentPath}/${textOnly ? 'text' : 'body'}',
        () =>
            (textOnly
                    ? Future<ChapterContent>.value(
                        _chapters['$bookId/${chapter.id}'] ??
                            _readChapterFile(bookId, chapter, textOnly: true),
                      )
                    : _chapter(bookId, chapter))
                .whenComplete(() {
                  _pendingChapters.remove('$bookId/${chapter.contentPath}/${textOnly ? 'text' : 'body'}');
                }),
      ),
    ),
    {
      'chapter': chapter.ordinal,
      'textOnly': textOnly,
      'migrating': _migrations.containsKey(bookId),
      'coalesced': _pendingChapters.containsKey(
        '$bookId/${chapter.contentPath}/${textOnly ? 'text' : 'body'}',
      ),
    },
  );

  @override
  Future<List<TocProgressEntry>?> readTocProgress(
    String bookId,
    String signature,
  ) async => cacheRoot == null
      ? null
      : TocProgressCache(cacheRoot!).read(bookId, signature);
  @override
  Future<void> writeTocProgress(
    String bookId,
    String signature,
    List<TocProgressEntry> entries,
  ) async {
    if (cacheRoot != null) {
      await TocProgressCache(cacheRoot!).write(bookId, signature, entries);
    }
  }

  Future<T> _read<T>(String bookId, Future<T> Function() action) async {
    while (_migrations.containsKey(bookId)) {
      await _migrations[bookId];
    }
    if (_closed) throw StateError('正文服务已关闭');
    if (_changing.contains(bookId)) throw StateError('这本书正在更新正文，请稍后再试');
    final task = action();
    final done = task.then<void>((_) {}, onError: (Object _) {});
    (_pending[bookId] ??= {}).add(done);
    try {
      return await task;
    } finally {
      _pending[bookId]?.remove(done);
      if (_pending[bookId]?.isEmpty == true) _pending.remove(bookId);
    }
  }

  /// 等所有章节/目录读取结束再改文件，旧读取不能在清缓存后重新填回旧正文。
  Future<void Function()> prepareContentChange(String bookId) async {
    if (!_changing.add(bookId)) throw StateError('这本书正在更新正文');
    try {
      await _migrations[bookId];
      await Future.wait(_pending[bookId]?.toList() ?? <Future<void>>[]);
      invalidate(bookId);
      // 删除和重解析也回收该书的磁盘缓存，不能只关闭内存中的旧章节。
      await (await _contentWorker()).clearCache(bookId);
    } catch (_) {
      _changing.remove(bookId);
      rethrow;
    }
    return () {
      invalidate(bookId);
      _changing.remove(bookId);
    };
  }

  /// 关闭后拒绝新读取，等所有已开始的文件读取结束再换书库目录。
  Future<void> close() async {
    _closed = true;
    await Future.wait(_migrations.values.toList());
    await Future.wait(_pending.values.expand((tasks) => tasks).toList());
    invalidate();
    if (_worker != null) await (await _worker!).close();
    _worker = null;
  }

  Future<ChapterContent> _chapter(String bookId, Chapter chapter) async {
    if (await _indexed(bookId, chapter)) {
      return (await _contentWorker()).chapter(bookId, chapter);
    }
    final key = '$bookId/${chapter.id}';
    final cached = _chapters[key];
    if (cached != null) {
      // 命中后移到队尾，LRU 淘汰的是最久未用的那一章
      _chapters.remove(key);
      _chapters[key] = cached;
      return cached;
    }
    var content = await _readChapterFile(bookId, chapter);
    if (chapter.href != null &&
        content.epubDetailsRevision < kEpubDetailsRevision) {
      final raw = content;
      final directory = p.dirname(chapterAbsolutePath(bookId, chapter));
      final source = bookSourcePath(p.join(libraryRoot, bookId), 'epub');
      content = await Isolate.run(
        () => enrichEpubContent(raw, chapter, directory, source),
      );
    }
    _chapters[key] = content;
    while (_chapters.length > cacheCapacity) {
      _chapters.remove(_chapters.keys.first);
    }
    return content;
  }

  Future<ChapterContent> _readChapterFile(
    String bookId,
    Chapter chapter, {
    bool textOnly = false,
  }) async {
    if (await _indexed(bookId, chapter)) {
      return (await _contentWorker()).chapter(
        bookId,
        chapter,
        textOnly: textOnly,
      );
    }
    final file = File(chapterAbsolutePath(bookId, chapter));
    if (!await file.exists()) {
      throw ContentFailure(ContentErrorCode.missing, file.path);
    }
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) {
        throw ContentFailure(ContentErrorCode.corrupted, file.path);
      }
      return ChapterContent.fromJson(decoded.cast<String, Object?>());
    } on FormatException catch (error) {
      throw ContentFailure(
        ContentErrorCode.corrupted,
        '$file.path：${error.message}',
      );
    }
  }

  @override
  Future<List<TocNode>> toc(String bookId, int contentVersion) =>
      _read(bookId, () {
        final key = '$bookId/$contentVersion';
        return _pendingTocs.putIfAbsent(
          key,
          () => _readToc(bookId, contentVersion).whenComplete(() {
            _pendingTocs.remove(key);
          }),
        );
      });

  Future<List<TocNode>> _readToc(String bookId, int contentVersion) async {
    final key = '$bookId/$contentVersion';
    if (_tocKey == key && _toc != null) return _toc!;
    final file = File(
      p.join(
        libraryRoot,
        bookId,
        'content',
        '$contentVersion',
        'manifest.json',
      ),
    );
    var nodes = const <TocNode>[];
    var chapters = const <Chapter>[];
    var encoding = '';
    Map<String, dynamic>? manifest;
    var tocRevision = 0;
    if (await file.exists()) {
      try {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is Map) {
          manifest = decoded.cast<String, dynamic>();
          tocRevision = (decoded['tocRevision'] as num?)?.toInt() ?? 0;
          encoding = decoded['encoding'] as String? ?? '';
          final rawToc = decoded['toc'];
          if (rawToc is List) {
            nodes = [
              for (final raw in rawToc)
                if (raw is Map) TocNode.fromJson(raw.cast<String, Object?>()),
            ];
          }
          final rawChapters = decoded['chapters'];
          if (rawChapters is List) {
            chapters = [
              for (final raw in rawChapters)
                if (raw is Map)
                  Chapter(
                    id: raw['id'] as String? ?? '',
                    ordinal: (raw['ordinal'] as num?)?.toInt() ?? 0,
                    title: raw['title'] as String? ?? '',
                    contentPath: raw['path'] as String? ?? '',
                    textLength: (raw['textLength'] as num?)?.toInt() ?? 0,
                    href: raw['href'] as String?,
                  ),
            ];
          }
        }
      } on FormatException {
        // 目录读不出来不阻断阅读：界面降级为章节平铺
        nodes = const [];
      }
    }
    // 新导入已生成完整目录。只有没有规则标记的旧书才修复，且按真实章节
    // 格式分支；本地 TXT 的 source.path 不能拿去尝试打开 EPUB 归档。
    if (tocRevision < kTocRevision && chapters.isNotEmpty) {
      final epub = chapters.any((chapter) => chapter.href != null);
      final directory = p.join(libraryRoot, bookId);
      final source = File(bookSourcePath(directory, epub ? 'epub' : 'txt'));
      if (await source.exists()) {
        try {
          if (epub) {
            final recovered = await _recoverLegacyToc(source.path, chapters);
            if (recovered.isNotEmpty) nodes = recovered;
          } else {
            nodes = await recoverTxtToc(
              bookDirectory: directory,
              chapters: chapters,
              nodes: nodes,
              encoding: encoding,
              preparation: textPreparation,
            );
          }
          // 只保存补齐的目录与完成标记，不重写正文、块号或阅读位置。
          if (manifest != null) {
            final next = File('${file.path}.next');
            await next.writeAsString(
              jsonEncode({
                ...manifest,
                'toc': nodes.map((node) => node.toJson()).toList(),
                'tocRevision': kTocRevision,
              }),
              flush: true,
            );
            await next.rename(file.path);
          }
        } on Object {
          // 原文件或修复保存失败时仍可用旧目录，下次读取可以继续尝试。
        }
      }
    }
    _tocKey = key;
    _toc = nodes;
    return nodes;
  }

  @override
  String resourceAbsolutePath(
    String bookId,
    int contentVersion,
    String resourcePath,
  ) => p.join(libraryRoot, bookId, 'content', '$contentVersion', resourcePath);

  @override
  String chapterAbsolutePath(String bookId, Chapter chapter) =>
      p.join(libraryRoot, bookId, chapter.contentPath);

  @override
  void invalidate([String? bookId]) {
    _storageModes.removeWhere(
      (directory, _) =>
          bookId == null || p.isWithin(p.join(libraryRoot, bookId), directory),
    );
    if (_worker != null) {
      unawaited(_worker!.then((worker) => worker.invalidate(bookId)));
    }
    if (bookId == null) {
      _chapters.clear();
    } else {
      _chapters.removeWhere((key, _) => key.startsWith('$bookId/'));
    }
    _tocKey = null;
    _toc = null;
  }

  /// 设置页复用既有「清理缓存」，正文任务排队执行，不与写入抢同一文件。
  Future<void> clearChapterCache() async {
    await (await _contentWorker()).clearCache();
  }

  /// 迁移等待旧读取结束，新读取等待迁移结束。和删除不同，等待期间继续显示旧页。
  Future<int> migrateContent(
    String bookId,
    int version,
    Future<int> Function() action,
  ) async {
    if (_closed || _changing.contains(bookId)) return 0;
    final finished = Completer<void>();
    _migrations[bookId] = finished.future;
    try {
      await Future.wait(_pending[bookId]?.toList() ?? <Future<void>>[]);
      // 旧 TXT 的目录补齐依赖旧块；在删除旧 JSON 前完成并保存。
      await _readToc(bookId, version);
      final bytes = await action();
      invalidate(bookId);
      return bytes;
    } finally {
      _migrations.remove(bookId);
      finished.complete();
    }
  }
}
