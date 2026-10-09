/// [ChapterContentRepository] 的文件实现。
///
/// 正文与目录都是导入时落盘的 JSON（设计文档 6.1），这里只做「读 + 小 LRU」，
/// 正文不做解析改写；旧 EPUB 目录从源书恢复。图片由界面按需解码。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

import '../../domain/models/book_document.dart';
import '../../domain/repositories/chapter_content_repository.dart';
import '../../domain/services/text_preparation.dart';
import '../../engine/parsers/epub/epub_parser.dart';
import '../services/recover_txt_toc.dart';
import '../services/book_source_path.dart';
import '../services/enrich_epub_content.dart';
import '../services/toc_progress_cache.dart';
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

  @override
  Future<ChapterContent> chapter(String bookId, Chapter chapter, {bool textOnly = false}) =>
    _read(bookId, () => textOnly
      ? Future.value(_chapters['$bookId/${chapter.id}'] ?? _readChapterFile(bookId, chapter))
      : _chapter(bookId, chapter));

  @override
  Future<List<TocProgressEntry>?> readTocProgress(String bookId, String signature) async =>
      cacheRoot == null ? null : TocProgressCache(cacheRoot!).read(bookId, signature);
  @override
  Future<void> writeTocProgress(String bookId, String signature, List<TocProgressEntry> entries) async {
    if (cacheRoot != null) await TocProgressCache(cacheRoot!).write(bookId, signature, entries);
  }

  Future<T> _read<T>(String bookId, Future<T> Function() action) async {
    if (_closed) throw StateError('正文服务已关闭');
    if (_changing.contains(bookId)) throw StateError('这本书正在更新正文，请稍后再试');
    final task = action();
    final done = task.then<void>((_) {}, onError: (Object _) {});
    (_pending[bookId] ??= {}).add(done);
    try { return await task; } finally {
      _pending[bookId]?.remove(done);
      if (_pending[bookId]?.isEmpty == true) _pending.remove(bookId);
    }
  }

  /// 等所有章节/目录读取结束再改文件，旧读取不能在清缓存后重新填回旧正文。
  Future<void Function()> prepareContentChange(String bookId) async {
    if (!_changing.add(bookId)) throw StateError('这本书正在更新正文');
    await Future.wait(_pending[bookId]?.toList() ?? <Future<void>>[]);
    invalidate(bookId);
    return () { invalidate(bookId); _changing.remove(bookId); };
  }

  /// 关闭后拒绝新读取，等所有已开始的文件读取结束再换书库目录。
  Future<void> close() async {
    _closed = true;
    await Future.wait(_pending.values.expand((tasks) => tasks).toList());
    invalidate();
  }

  Future<ChapterContent> _chapter(String bookId, Chapter chapter) async {
    final key = '$bookId/${chapter.id}';
    final cached = _chapters[key];
    if (cached != null) {
      // 命中后移到队尾，LRU 淘汰的是最久未用的那一章
      _chapters.remove(key);
      _chapters[key] = cached;
      return cached;
    }
    var content = await _readChapterFile(bookId, chapter);
    if (chapter.href != null) {
      final raw = content;
      final directory = p.dirname(chapterAbsolutePath(bookId, chapter));
      final source = bookSourcePath(p.join(libraryRoot, bookId), 'epub');
      content = await Isolate.run(() => enrichEpubContent(raw, chapter, directory, source));
    }
    _chapters[key] = content;
    while (_chapters.length > cacheCapacity) {
      _chapters.remove(_chapters.keys.first);
    }
    return content;
  }

  Future<ChapterContent> _readChapterFile(
    String bookId,
    Chapter chapter,
  ) async {
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
      throw ContentFailure(ContentErrorCode.corrupted, '$file.path：${error.message}');
    }
  }

  @override
  Future<List<TocNode>> toc(String bookId, int contentVersion) =>
    _read(bookId, () => _readToc(bookId, contentVersion));

  Future<List<TocNode>> _readToc(String bookId, int contentVersion) async {
    final key = '$bookId/$contentVersion';
    if (_tocKey == key && _toc != null) return _toc!;
    final file = File(p.join(
      libraryRoot,
      bookId,
      'content',
      '$contentVersion',
      'manifest.json',
    ));
    var nodes = const <TocNode>[];
    var chapters = const <Chapter>[];
    var encoding = '';
    if (await file.exists()) {
      try {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is Map) {
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
    // 老清单会漏层级、漏锚点；是否需要恢复与章长、条目数量无关。
    // 每本书首次读取在后台按源书重建，后续读取使用本仓库缓存。
    final source = File(bookSourcePath(p.join(libraryRoot, bookId), 'epub'));
    if (chapters.isNotEmpty && await source.exists()) {
      try {
        final recovered = await _recoverLegacyToc(source.path, chapters);
        if (recovered.isNotEmpty) nodes = recovered;
      } on Object {
        // 源 EPUB 损坏时仍使用已落盘目录，不阻断阅读。
      }
    }
    if (chapters.isNotEmpty) {
      try {
        nodes = await recoverTxtToc(bookDirectory: p.join(libraryRoot, bookId),
          chapters: chapters, nodes: nodes, encoding: encoding,
          preparation: textPreparation);
      } on Object {
        // 源文件缺失、编码或正文损坏时沿用旧目录，不改书库数据。
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
  ) =>
      p.join(libraryRoot, bookId, 'content', '$contentVersion', resourcePath);

  @override
  String chapterAbsolutePath(String bookId, Chapter chapter) =>
      p.join(libraryRoot, bookId, chapter.contentPath);

  @override
  void invalidate([String? bookId]) {
    if (bookId == null) {
      _chapters.clear();
    } else {
      _chapters.removeWhere((key, _) => key.startsWith('$bookId/'));
    }
    _tocKey = null;
    _toc = null;
  }
}
