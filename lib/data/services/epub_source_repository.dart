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

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'book_source_path.dart';

import '../../../domain/models/book_document.dart';
import '../../../domain/repositories/chapter_content_repository.dart';
import '../../engine/normalization/text_decoding.dart';
import '../../engine/parsers/epub/epub_archive.dart';
import '../../engine/parsers/epub/epub_sanitizer.dart';
import '../../engine/layout/english_hyphenation.dart';
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
  bool _closed = false;
  Set<String> get activeBookIds => _sessions.map((s) => s.bookId).toSet();

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
    for (final session in _sessions.where((s) => s.bookId == bookId).toList()) {
      await session._drainAndClose();
    }
    return () => _changing.remove(bookId);
  }

  Future<void> close() async {
    _closed = true;
    for (final session in _sessions.toList()) {
      await session._drainAndClose();
    }
  }

  /// 打开一本书的原书内容。
  ///
  /// 源文件缺失或与章节索引对不上时抛 [ContentFailure]，由调用方降级回简化模式。
  EpubSourceSession open({
    required String bookId,
    required int contentVersion,
    required List<Chapter> chapters,
  }) {
    if (_closed) throw StateError('原书服务已关闭');
    if (_changing.contains(bookId)) throw StateError('这本书正在更新正文');
    final reader = EpubSourceReader.open(
      bookSourcePath(p.join(libraryRoot, bookId), 'epub'),
    );
    final mismatch = reader.mismatchWith(chapters);
    if (mismatch != null) {
      reader.close();
      throw ContentFailure(
        ContentErrorCode.corrupted,
        '原书文件与章节索引不一致：$mismatch',
      );
    }
    final session = EpubSourceSession._(
      repository: this,
      bookId: bookId,
      contentVersion: contentVersion,
      reader: reader,
    );
    _sessions.add(session);
    return session;
  }
}

/// 一本书的原书内容会话。界面离开阅读页时 [close]。
class EpubSourceSession {
  EpubSourceSession._({
    required EpubSourceRepository repository,
    required this.bookId,
    required this.contentVersion,
    required EpubSourceReader reader,
  }) : _repository = repository,
       _libraryRoot = repository.libraryRoot,
       _cacheRoot = repository.cacheRoot,
       _reader = reader {
    for (var i = 0; i < reader.chapterCount; i++) {
      final entry = reader.entryPathAt(i);
      _chapterEntries.add(entry);
      _ordinalOfEntry[entry] = i;
    }
  }

  final String bookId;
  final EpubSourceRepository _repository;
  final int contentVersion;
  final EpubSourceReader _reader;
  final String _libraryRoot;
  final String _cacheRoot;

  /// spine 条目（这些进 WebView 前要净化）
  final _chapterEntries = <String>{};

  /// 归档内路径 → 章序（书内链接换章时要用它反查目标章）
  final _ordinalOfEntry = <String, int>{};

  /// 同一个条目的并发请求（图片常被同时请求多张）：读归档的机会只有一次，
  /// 必须串行化，否则第二次会撞上「已读过一次」的保护。
  final _pending = <String, Future<Uint8List?>>{};

  bool _closed = false;

  /// 章节数
  int get chapterCount => _reader.chapterCount;

  /// `/bookId/版本/` 这一段 URL 前缀（不含主机），拦截器用它快速筛掉不属于本书的请求
  String get pathPrefix => '/$bookId/$contentVersion/';

  /// 第 [ordinal] 章的虚拟源 URL（WebView 的文档地址）
  Uri chapterUrl(int ordinal) => urlOf(_reader.entryPathAt(ordinal));

  /// 某条目的虚拟源 URL（相对引用由 WebView 按标准 URL 算法自行解析）
  Uri urlOf(String entryPath) =>
      Uri.parse('https://$kEpubSourceHost$pathPrefix$entryPath');

  /// 第 [ordinal] 章的归档内路径
  String chapterEntryPath(int ordinal) => _reader.entryPathAt(ordinal);

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
    final bytes = await _load(entryPath);
    if (bytes == null) return null;
    return EpubResource(bytes: bytes, contentType: _contentTypeOf(entryPath));
  }

  /// 第 [ordinal] 章的净化文档（HTML 字符串）；条目缺失返回 null。
  Future<String?> chapterDocument(int ordinal) async {
    final bytes = await _load(_reader.entryPathAt(ordinal));
    if (bytes == null) return null;
    return decodeTextBytes(bytes);
  }

  /// 换章时重置归档的解压总量预算（见 [EpubSourceReader.resetBudget]）。
  void resetBudget() => _reader.resetBudget();

  /// 预取某一章：解出并落盘，换章时不用现解（相邻章在阅读时提前做，见计划 3.1）。
  ///
  /// 越界直接返回；失败也不抛——预取失败只是让换章慢一点，正式加载时会再解一次。
  Future<void> prefetchChapter(int ordinal) async {
    if (ordinal < 0 || ordinal >= chapterCount) return;
    try {
      await _load(_reader.entryPathAt(ordinal));
    } on Object {
      // 预取失败不影响阅读
    }
  }

  /// 关闭归档句柄。重复调用安全。
  void close() {
    if (_closed) return;
    _closed = true;
    _reader.close();
    if (_pending.isEmpty) _repository._sessions.remove(this);
  }

  Future<void> _drainAndClose() async {
    // 阻止新资源读取，已有请求完成后再释放归档；旧会话之后只能返回 404。
    final pending = _pending.values.toList();
    await Future.wait(
      pending.map((f) => f.then<void>((_) {}, onError: (Object _) {})),
    );
    close();
  }

  /// 取条目的字节：导入落盘副本 → 会话缓存 → 归档（每个条目只有这一次机会）。
  Future<Uint8List?> _load(String entryPath) {
    if (_closed ||
        _repository._closed ||
        _repository._changing.contains(bookId)) {
      return Future.value(null);
    }
    final pending = _pending[entryPath];
    if (pending != null) return pending;
    final future = _loadUncached(entryPath);
    _pending[entryPath] = future;
    return future.whenComplete(() {
      _pending.remove(entryPath);
      if (_closed && _pending.isEmpty) _repository._sessions.remove(this);
    });
  }

  Future<Uint8List?> _loadUncached(String entryPath) async {
    if (!_reader.containsEntry(entryPath)) return null;
    if (_chapterEntries.contains(entryPath) && _repository.hyphenateText) {
      await EnglishHyphenation.prepare();
    }

    // 1. 图片：导入时已落盘的副本（设计文档 6.1），不读归档也不占缓存
    final imported = File(
      p.join(
        _libraryRoot,
        bookId,
        'content',
        '$contentVersion',
        'res',
        entryPath,
      ),
    );
    if (await imported.exists()) return imported.readAsBytes();

    // 2. 本会话（或上次会话）解出的缓存
    final cached = File(_cachePathOf(entryPath));
    if (await cached.exists()) {
      try {
        return await cached.readAsBytes();
      } on FileSystemException {
        // 缓存读坏了就当没有，走归档重来
      }
    }

    // 3. 归档：读过即消费，所以必须先落盘再返回
    final raw = _reader.readEntry(entryPath);
    if (raw == null) return null;
    final bytes = _transform(entryPath, raw);
    if (bytes.length <= EpubArchive.maxEntryBytes) {
      await _writeCache(cached, bytes);
    }
    return bytes;
  }

  /// 章节净化、字体解混淆，其余（CSS、图片）原样。
  Uint8List _transform(String entryPath, Uint8List raw) {
    if (_chapterEntries.contains(entryPath)) {
      final sanitized = EpubSanitizer.sanitize(decodeTextBytes(raw)).html;
      return Uint8List.fromList(
        utf8.encode(
          _repository.hyphenateText
              ? EnglishHyphenation.document(sanitized)
              : sanitized,
        ),
      );
    }
    final algorithm = _reader.fonts.algorithmOf(entryPath);
    if (algorithm != null) {
      return _reader.fonts
          .deobfuscate(entryPath, raw, _reader.uniqueIdentifier)
          .bytes;
    }
    return raw;
  }

  /// 缓存路径：`cache/original/<bookId>/<版本>/<归档内路径>`。
  String _cachePathOf(String entryPath) => p.join(
    _cacheRoot,
    'original',
    bookId,
    '$contentVersion',
    _repository.hyphenateText ? 'hyphen1' : 'source1',
    entryPath,
  );

  Future<void> _writeCache(File file, Uint8List bytes) async {
    try {
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes, flush: false);
    } on FileSystemException {
      // 缓存写不进去不影响这次阅读（下次再解一遍）
    }
  }

  /// 响应头的 Content-Type。
  ///
  /// 净化后的章节按 `text/html` 给出：产物是 HTML 序列化结果，用 XHTML 的
  /// `application/xhtml+xml` 会让浏览器走严格 XML 解析器，反而容易报错。
  String _contentTypeOf(String entryPath) {
    if (_chapterEntries.contains(entryPath)) return 'text/html; charset=utf-8';
    final declared = _reader.mediaTypeOf(entryPath);
    if (declared.startsWith('text/')) return '$declared; charset=utf-8';
    return declared;
  }
}
