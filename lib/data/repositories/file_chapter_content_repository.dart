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
import '../../domain/models/locator.dart';
import '../../engine/normalization/source_position_matcher.dart';
import '../../domain/repositories/chapter_content_repository.dart';
import '../../domain/services/text_preparation.dart';
import '../../engine/parsers/epub/epub_parser.dart';
import '../services/recover_txt_toc.dart';
import '../services/book_source_path.dart';
import '../services/enrich_epub_content.dart';
import '../services/toc_progress_cache.dart';
import '../services/chapter_content_worker.dart';
import '../services/chapter_manifest.dart';
import '../services/publication_cache.dart';
import '../../engine/parsers/pdf/pdf_file.dart';
import '../../engine/parsers/pdf/pdf_page_pictures.dart';
import '../../domain/services/toc_entry_index.dart';

part '../services/pdf_chapter_reading.dart';

Future<List<TocNode>> _recoverLegacyToc(
  String sourcePath,
  List<Chapter> chapters,
) => Isolate.run(() => EpubParser.resolveLegacyToc(sourcePath, chapters));

// 独立入口只捕获路径与快照；不能把持有连接/在途任务的正文仓库发送出去。
typedef _PositionWork = (String, String?, String, List<Chapter>, List<Locator>);
Future<Map<String, Locator?>> _matchInBackground(_PositionWork input) =>
    Isolate.run(() => _matchPositions(input));
Future<Map<String, Locator?>> _matchPositions(_PositionWork input) async {
  final (library, cache, bookId, chapters, anchors) = input;
  final contents = FileChapterContentRepository(
    libraryRoot: library,
    cacheRoot: cache,
  );
  try {
    final matcher = SourcePositionMatcher(anchors);
    for (final chapter in chapters) {
      final content = await contents.chapter(bookId, chapter, textOnly: true);
      matcher.add(chapter.id, content.blocks);
    }
    return matcher.finish();
  } finally {
    await contents.close();
  }
}

class FileChapterContentRepository implements ChapterContentRepository {
  @override
  Future<Map<String, Locator?>?> matchSourcePositions(
    String bookId,
    List<Chapter> chapters,
    List<Locator> anchors,
  ) => _read(
    bookId,
    () =>
        _matchInBackground((libraryRoot, cacheRoot, bookId, chapters, anchors)),
  );

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
  final _pdfBooks = <String>{};
  final _pdfReaders = <String, Future<PdfFile>>{};
  final _pdfClosings = <Future<void>>{};
  final _manifests = <String, Future<ChapterManifest?>>{};
  final _publicationResources = <String, (String, Set<String>)>{};
  final _pendingChapters = <String, Future<ChapterContent>>{};
  final _migrations = <String, Future<void>>{};
  final _migrationCancellations = <String, void Function()>{};
  final _usedBooks = <String>{};
  Set<String> get usedBookIds => Set.unmodifiable(_usedBooks);

  Future<ChapterContentWorker> _contentWorker() =>
      _worker ??= ChapterContentWorker.open(
        libraryRoot: libraryRoot,
        cacheRoot: cacheRoot,
        preparation: textPreparation,
      );

  /// 同一次开书的正文和目录共用清单；换书只保留最近四份，更新/恢复时一并作废。
  Future<ChapterManifest?> _manifest(String directory) {
    final pending = _manifests.remove(directory) ?? _readManifest(directory);
    _manifests[directory] = pending;
    while (_manifests.length > 4) {
      _manifests.remove(_manifests.keys.first);
    }
    return pending;
  }

  Future<ChapterManifest?> _readManifest(String directory) async {
    final relative = p.relative(directory, from: libraryRoot);
    final parts = p.split(relative);
    return (await _contentWorker()).manifest(
      parts.first,
      p.joinAll(parts.skip(1)),
    );
  }

  /// 仅供更新前补充旧定位证据。只读旧版本的正文/缓存，不读取已改变的源文件。
  Future<ChapterContent?> cachedPreviousChapter(
    String bookId,
    Chapter chapter,
  ) async {
    final memory = _chapters['$bookId/${chapter.id}'];
    if (memory != null) return memory;
    if (await _indexed(bookId, chapter)) {
      return (await _contentWorker()).cachedPreviousChapter(bookId, chapter);
    }
    final file = File(chapterAbsolutePath(bookId, chapter));
    if (!await file.exists()) return null;
    return ChapterContent.fromJson(
      (jsonDecode(await file.readAsString()) as Map).cast<String, Object?>(),
    );
  }

  Future<bool> _indexed(String bookId, Chapter chapter) {
    final directory = p.dirname(chapterAbsolutePath(bookId, chapter));
    return _storageModes.putIfAbsent(directory, () async {
      final manifest = await _manifest(directory);
      final index = manifest?.sourceIndex;
      if (index == null) return false;
      if (index.format == 'pdf') _pdfBooks.add(bookId);
      if (index.format != 'txt') {
        _publicationResources['$bookId/${p.basename(directory)}'] = (
          PublicationCache.assets(
            PublicationCache.effectiveRoot(libraryRoot, cacheRoot),
            bookId,
            index.sourceDigest,
          ),
          {
            for (final entry in index.images.entries)
              if (entry.value[0] >= 0) 'res/${entry.key}',
          },
        );
      }
      return true;
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
  TocLocations? _tocLocations;
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
                  _pendingChapters.remove(
                    '$bookId/${chapter.contentPath}/${textOnly ? 'text' : 'body'}',
                  );
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
  ) => _read(
    bookId,
    () async => cacheRoot == null
        ? null
        : TocProgressCache(cacheRoot!).read(bookId, signature),
  );
  @override
  Future<void> writeTocProgress(
    String bookId,
    String signature,
    List<TocProgressEntry> entries,
  ) async {
    // 标题任务在调用前复查Reader的存活状态；这里再拒绝交接期间的新写入，
    // 已经开始的写盘纳入同一等待，清理完成后不能迟到写回。
    if (cacheRoot != null && !_closed && !_changing.contains(bookId)) {
      await _read(
        bookId,
        () => TocProgressCache(cacheRoot!).write(bookId, signature, entries),
      );
    }
  }

  Future<T> _read<T>(String bookId, Future<T> Function() action) async {
    _usedBooks.add(bookId);
    while (_migrations.containsKey(bookId)) {
      _migrationCancellations[bookId]?.call();
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
      await _closePdfReaders(bookId);
      invalidate(bookId);
      // 删除和重解析也回收该书的磁盘缓存，不能只关闭内存中的旧章节。
      await (await _contentWorker()).clearCache(bookId);
      if (cacheRoot != null) await TocProgressCache(cacheRoot!).clear(bookId);
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
    await _closePdfReaders(null);
    await Future.wait(_pdfClosings.toList());
    invalidate();
    if (_worker != null) await (await _worker!).close();
    _worker = null;
  }

  Future<ChapterContent> _chapter(String bookId, Chapter chapter) async {
    if (await _indexed(bookId, chapter)) {
      if (_pdfBooks.contains(bookId)) return _pdfChapter(bookId, chapter);
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
      if (!textOnly && _pdfBooks.contains(bookId)) {
        return _pdfChapter(bookId, chapter);
      }
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
    TocLocations? locations;
    if (await file.exists()) {
      try {
        final snapshot = await _manifest(p.dirname(file.path));
        final decoded = snapshot?.data;
        if (decoded != null) {
          manifest = decoded;
          if (snapshot!.sourceIndex case final index?) {
            locations = (
              anchors: index.tocPositions,
              headings: index.tocHeadings,
            );
          }
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
            _manifests.remove(p.dirname(file.path));
          }
        } on Object {
          // 原文件或修复保存失败时仍可用旧目录，下次读取可以继续尝试。
        }
      }
    }
    _tocKey = key;
    _toc = nodes;
    _tocLocations = locations;
    return nodes;
  }

  @override
  Future<TocLocations?> tocLocations(String bookId, int contentVersion) async {
    await toc(bookId, contentVersion);
    return _tocKey == '$bookId/$contentVersion' ? _tocLocations : null;
  }

  @override
  String resourceAbsolutePath(
    String bookId,
    int contentVersion,
    String resourcePath,
  ) {
    final store = _publicationResources['$bookId/$contentVersion'];
    if (store != null &&
        resourcePath.startsWith('res/') &&
        !store.$2.contains(resourcePath)) {
      return p.join(store.$1, resourcePath.substring(4));
    }
    return p.join(
      libraryRoot,
      bookId,
      'content',
      '$contentVersion',
      resourcePath,
    );
  }

  @override
  String chapterAbsolutePath(String bookId, Chapter chapter) =>
      p.join(libraryRoot, bookId, chapter.contentPath);

  @override
  void invalidate([String? bookId]) {
    unawaited(_closePdfReaders(bookId));
    if (bookId == null) {
      _pdfBooks.clear();
    } else {
      _pdfBooks.remove(bookId);
    }
    _manifests.removeWhere(
      (directory, _) =>
          bookId == null || p.isWithin(p.join(libraryRoot, bookId), directory),
    );
    _publicationResources.removeWhere(
      (key, _) => bookId == null || key.startsWith('$bookId/'),
    );
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
    _tocLocations = null;
  }

  /// 设置页复用既有「清理缓存」，正文任务排队执行，不与写入抢同一文件。
  Future<void> clearChapterCache() async {
    await (await _contentWorker()).clearCache();
  }

  /// 迁移等待旧读取结束，新读取等待迁移结束。和删除不同，等待期间继续显示旧页。
  Future<int> migrateContent(
    String bookId,
    int version,
    Future<int> Function() action, {
    void Function()? onReadRequested,
  }) async {
    if (_closed || _changing.contains(bookId)) return 0;
    final finished = Completer<void>();
    _migrations[bookId] = finished.future;
    if (onReadRequested != null) {
      _migrationCancellations[bookId] = onReadRequested;
    }
    try {
      await Future.wait(_pending[bookId]?.toList() ?? <Future<void>>[]);
      // 旧 TXT 的目录补齐依赖旧块；在删除旧 JSON 前完成并保存。
      await _readToc(bookId, version);
      final bytes = await action();
      invalidate(bookId);
      return bytes;
    } finally {
      _migrationCancellations.remove(bookId);
      _migrations.remove(bookId);
      finished.complete();
    }
  }
}
