/// 原书排版模式的内容服务：把「归档里的原始文件」变成「WebView 能取到的字节」。
///
/// 三件事：
/// 1. **虚拟源**：所有资源都挂在 `https://gtbook.internal/<bookId>/<版本>/<归档内路径>`。
///    域名不存在，每个请求都由拦截器直接应答（本地字节或 404），因此书里写的外网
///    图片、外链样式也不会有任何真实网络请求（docs/原书排版模式实现计划.md 3.2）。
/// 2. **解出内容落盘**：章节净化后、字体解混淆后写 `cache/original/...`，
///    属可重建缓存（设计文档 7.3）。这是必须的：归档层「一个条目只能读一次」
///    （见 [EpubSourceReader.readEntry]），不落盘第二次请求就没法应答。
/// 3. **图片优先用导入时的落盘副本**（`content/<版本>/res/`），既不读归档也不占缓存。
library;

import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:flutter/services.dart';

import 'epub_source_worker.dart';

import '../../../domain/models/book_document.dart';
import '../../../domain/repositories/chapter_content_repository.dart';
import '../../engine/parsers/epub/epub_archive.dart';
import '../../engine/parsers/epub/epub_source_reader.dart';

/// 虚拟源域名：不解析、不可达，纯粹给 WebView 一个稳定的同源基准。
const String kEpubSourceHost = 'gtbook.internal';

/// 一次资源请求的应答。
class EpubResource {
  const EpubResource({required this.bytes, required this.contentType});

  final Uint8List bytes;
  final String contentType;
}

/// 内容服务（应用级单例，按书开 [EpubSourceSession]）。
class EpubSourceRepository {
  EpubSourceRepository({
    required this.libraryRoot,
    required this.cacheRoot,
    this.hyphenateText = true,
  });

  /// 后台目录解析只需要源文字，不加载 Flutter 字典资源，也不准备显示断点。
  final bool hyphenateText;

  /// `files/library` 绝对路径
  final String libraryRoot;

  /// 缓存根目录；原书模式解出的内容放它下面的 `original/`
  final String cacheRoot;
  final _sessions = <EpubSourceSession>{};
  final _changing = <String>{};
  final _opening = <Future<EpubSourceSession>, String>{};
  bool _closed = false;
  Set<String> get activeBookIds => {
    ..._sessions.map((s) => s.bookId),
    ..._opening.values,
  };
  Future<void> _waitOpening([String? bookId]) async {
    await Future.wait(
      _opening.entries
          .where((e) => bookId == null || e.value == bookId)
          .map((e) => e.key.then<void>((_) {}, onError: (Object _) {})),
    );
  }

  /// 检查与重命名之间不让出事件循环，新会话从干净路径重新准备。
  /// 只挪走没有会话的缓存，已打开归档读过的条目仍能继续使用。
  Directory? detachUnusedCache(
    Directory directory,
    Set<String> protectedBooks,
  ) {
    final root = p.join(cacheRoot, 'original');
    if (!p.isWithin(root, directory.path) ||
        p.dirname(directory.path) != root) {
      return null;
    }
    final bookId = p.basename(directory.path);
    if (protectedBooks.contains(bookId) ||
        activeBookIds.contains(bookId) ||
        _changing.contains(bookId)) {
      return null;
    }
    if (!directory.existsSync()) return null;
    final trash = Directory(p.join(cacheRoot, 'cleanup'))
      ..createSync(recursive: true);
    return directory.renameSync(
      p.join(trash.path, '$bookId-${DateTime.now().microsecondsSinceEpoch}'),
    );
  }

  Future<void Function()> prepareContentChange(String bookId) async {
    if (!_changing.add(bookId)) throw StateError('这本书正在更新正文');
    try {
      await _waitOpening(bookId);
      for (final session
          in _sessions.where((s) => s.bookId == bookId).toList()) {
        await session.close();
      }
      // bookId 与正文规则版本不会因源文件编辑而变化。关闭旧读取后清掉旧网页、字体和图片缓存。
      final cached = Directory(p.join(cacheRoot, 'original', bookId));
      if (await cached.exists()) await cached.delete(recursive: true);
    } catch (_) {
      _changing.remove(bookId);
      rethrow;
    }
    return () => _changing.remove(bookId);
  }

  Future<void> close() async {
    _closed = true;
    await _waitOpening();
    for (final session in _sessions.toList()) {
      await session.close();
    }
  }

  /// 打开一本书的原书内容。
  ///
  /// 源文件缺失或与章节索引对不上时抛 [ContentFailure]，由调用方降级回简化模式。
  Future<EpubSourceSession> open({
    required String bookId,
    required int contentVersion,
    required List<Chapter> chapters,
  }) {
    if (_closed) throw StateError('原书服务已关闭');
    if (_changing.contains(bookId)) throw StateError('这本书正在更新正文');
    // 打开期间也保护缓存与源文件，恢复/重导入必须等待后台归档关闭。
    final opening = _open(bookId, contentVersion, chapters);
    _opening[opening] = bookId;
    return opening.whenComplete(() => _opening.remove(opening));
  }

  Future<EpubSourceSession> _open(
    String bookId,
    int contentVersion,
    List<Chapter> chapters,
  ) async {
    // 平台资源只读取字节，词典解析留给后台；缓存命中时不解析词典。
    final dictionary = hyphenateText
        ? await rootBundle.load('assets/hyphenation/hyph_en_US.dic')
        : null;
    final worker = await EpubSourceWorker.open(
      libraryRoot: libraryRoot,
      cacheRoot: cacheRoot,
      bookId: bookId,
      contentVersion: contentVersion,
      chapters: chapters,
      dictionary: dictionary?.buffer.asUint8List(
        dictionary.offsetInBytes,
        dictionary.lengthInBytes,
      ),
    );
    if (_closed || _changing.contains(bookId)) {
      await worker.close();
      throw StateError('原书会话在打开期间已关闭');
    }
    final session = EpubSourceSession._(
      this,
      worker,
      bookId: bookId,
      contentVersion: contentVersion,
    );
    _sessions.add(session);
    return session;
  }
}

/// 一本书的原书内容会话。界面离开阅读页时 [close]。
class EpubSourceSession {
  EpubSourceSession._(
    this._repository,
    this._worker, {
    required this.bookId,
    required this.contentVersion,
  }) {
    for (var i = 0; i < _worker.entries.length; i++) {
      final entry = _worker.entries[i];
      _chapterEntries.add(entry);
      _ordinalOfEntry[entry] = i;
    }
  }

  final String bookId;
  final EpubSourceRepository _repository;
  final int contentVersion;
  final EpubSourceWorker _worker;

  /// spine 条目（这些进 WebView 前要净化）
  final _chapterEntries = <String>{};

  /// 归档内路径 → 章序（书内链接换章时要用它反查目标章）
  final _ordinalOfEntry = <String, int>{};

  // 等到资源完整返回并落盘，才允许恢复/清理接管这本书的文件。
  final _pending = <Future<Object?>>{};
  Future<void>? _closing;

  bool _closed = false;

  /// 章节数
  int get chapterCount => _worker.entries.length;

  /// `/bookId/版本/` 这一段 URL 前缀（不含主机），拦截器用它快速筛掉不属于本书的请求
  String get pathPrefix => '/$bookId/$contentVersion/';

  /// 第 [ordinal] 章的虚拟源 URL（WebView 的文档地址）
  Uri chapterUrl(int ordinal) => urlOf(_worker.entries[ordinal]);

  /// 某条目的虚拟源 URL（相对引用由 WebView 按标准 URL 算法自行解析）
  Uri urlOf(String entryPath) =>
      Uri.parse('https://$kEpubSourceHost$pathPrefix$entryPath');

  /// 第 [ordinal] 章的归档内路径
  String chapterEntryPath(int ordinal) => _worker.entries[ordinal];

  /// 该条目是否是 spine 里的章节文档（章节要净化并在进 WebView 前注入框架资源）
  bool isChapterEntry(String entryPath) => _chapterEntries.contains(entryPath);

  /// 归档内路径 → 章序；不属于 spine 时返回 null（书内链接的兜底判断）
  int? ordinalOfEntry(String entryPath) => _ordinalOfEntry[entryPath];

  /// 书内链接的落点：把 [href] 按当前章的文档地址 [base] 解析，得到目标章序与锚点。
  ///
  /// 指向书外（http、别的域名）、指向不存在的条目、或指向 spine 之外的条目时
  /// 返回 null——调用方据此忽略这次点击（计划 3.2：书外链接忽略）。
  ({int ordinal, String fragment})? resolveLink(Uri base, String href) {
    final url = base.resolve(href);
    final entryPath = entryPathOf(url);
    if (entryPath == null) return null;
    final ordinal = _ordinalOfEntry[entryPath];
    if (ordinal == null) return null;
    return (ordinal: ordinal, fragment: url.fragment);
  }

  /// 虚拟源 URL → 归档内路径；不属于本书、版本不符或越界时返回 null。
  String? entryPathOf(Uri url) {
    if (url.host != kEpubSourceHost) return null;
    final segments = url.pathSegments;
    if (segments.length < 3) return null;
    if (segments[0] != bookId || segments[1] != '$contentVersion') return null;
    // pathSegments 已按段解码，再用归档层的规范化口径挡掉越界路径
    return normalizeEntryPath(segments.skip(2).join('/'));
  }

  /// 一次资源请求的应答；返回 null 表示 404（条目不存在或越界）。
  Future<EpubResource?> resourceFor(Uri url) async {
    final entryPath = entryPathOf(url);
    if (entryPath == null) return null;
    final result = await _read(() => _worker.resource(entryPath));
    if (result == null) return null;
    return EpubResource(bytes: result.bytes, contentType: result.contentType);
  }

  /// 第 [ordinal] 章的净化文档（HTML 字符串）；条目缺失返回 null。
  Future<String?> chapterDocument(int ordinal) async {
    return _read(() => _worker.document(_worker.entries[ordinal]));
  }

  /// 换章时重置归档的解压总量预算（见 [EpubSourceReader.resetBudget]）。
  void resetBudget() {
    if (!_closed) _worker.resetBudget();
  }

  /// 预取某一章：解出并落盘，换章时不用现解（相邻章在阅读时提前做，见计划 3.1）。
  ///
  /// 越界直接返回；失败也不抛——预取失败只是让换章慢一点，正式加载时会再解一次。
  Future<void> prefetchChapter(int ordinal) async {
    if (ordinal < 0 || ordinal >= chapterCount) return;
    try {
      await _read<void>(() => _worker.prefetch(_worker.entries[ordinal]));
    } on Object {
      // 预取失败不影响阅读
    }
  }

  /// 立即停止接受新请求，已有资源落盘后关闭后台归档。重复调用共用结果。
  Future<void> close() {
    _closed = true;
    return _closing ??= _drainAndClose();
  }

  Future<void> _drainAndClose() async {
    try {
      await Future.wait(
        _pending.toList().map(
          (f) => f.then<void>((_) {}, onError: (Object _) {}),
        ),
      );
      await _worker.close();
    } finally {
      _repository._sessions.remove(this);
    }
  }

  Future<T?> _read<T>(Future<T?> Function() read) {
    if (_closed ||
        _repository._closed ||
        _repository._changing.contains(bookId)) {
      return Future.value(null);
    }
    final future = read();
    _pending.add(future);
    return future.whenComplete(() => _pending.remove(future));
  }
}
