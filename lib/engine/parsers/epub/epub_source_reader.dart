/// 原书排版模式的内容来源：直接读导入时保留的 `source.epub`。
///
/// 与导入解析读的是同一份归档，但用途不同：导入把正文标准化成 JSON 块，
/// 这里保留原始 XHTML / CSS / 字体，交给 WebView 按原书样式渲染
/// （设计文档 3.2、`docs/原书排版模式实现计划.md` 3.1）。
///
/// 章节与数据库 `chapters` 表按 ordinal 对齐，并校验章节 ID 内嵌的条目哈希
/// （生成规则见 [epubChapterId]，导入端用的是同一个函数）。对不上说明源文件
/// 与数据库不是同一次导入的产物，直接报错，不猜、不静默降级。
///
/// 条目字节按需解压，不整本进内存；安全阈值沿用 [EpubArchive]（设计文档 6.1）。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../../../core/errors/import_error.dart';
import '../../../domain/models/book_document.dart';
import '../../../domain/repositories/chapter_content_repository.dart';
import 'epub_archive.dart';
import 'epub_package.dart';
import 'font_deobfuscator.dart';

/// 章节 ID：`ch<四位 spine 序>-<条目路径哈希>`。
///
/// 导入解析与读源共用这一处规则（设计文档 6.1：同输入稳定、文件名安全）。
/// 首版导入端用的哈希算法，改动会让老库全部对不上，因此这里保持不动。
String epubChapterId(int ordinal, String entryPath) {
  final hash = sha256.convert(utf8.encode(entryPath)).toString();
  return 'ch${(ordinal + 1).toString().padLeft(4, '0')}-${hash.substring(0, 8)}';
}

class EpubSourceReader {
  EpubSourceReader._(
    this._archive,
    this._entryPaths,
    this._mediaTypes,
    this._uniqueIdentifier,
    this._opfPath,
    this._fonts,
  );

  final EpubArchive _archive;

  /// spine 顺序的归档内路径（下标即 `Chapter.ordinal`）
  final List<String> _entryPaths;

  /// 归档内路径 → media-type（来自 OPF manifest，用于响应 Content-Type）
  final Map<String, String> _mediaTypes;

  /// 出版标识：嵌入字体解混淆的 key 来源
  final String _uniqueIdentifier;

  /// OPF 路径：解析归档内相对引用时的基准之一
  final String _opfPath;

  final EpubFontDeobfuscator _fonts;

  bool _closed = false;

  /// 出版标识（[EpubPackage.uniqueIdentifier]）
  String get uniqueIdentifier => _uniqueIdentifier;

  /// OPF 路径
  String get opfPath => _opfPath;

  /// 嵌入字体的解混淆表
  EpubFontDeobfuscator get fonts => _fonts;

  /// 打开源文件并解析 spine。
  ///
  /// [sourcePath] 是 `files/library/<bookId>/source.epub` 的绝对路径。
  /// 打开或结构解析失败时抛 [ContentFailure]（这是「读内容」阶段，不是导入）。
  static EpubSourceReader open(
    String sourcePath, {
    bool directory = false,
    Map<String, String> digests = const {},
    EpubArchive? entryArchive,
  }) {
    if (entryArchive == null &&
        !(directory
            ? Directory(sourcePath).existsSync()
            : File(sourcePath).existsSync())) {
      throw ContentFailure(ContentErrorCode.missing, '缺少原书文件：$sourcePath');
    }
    EpubArchive? archive = entryArchive;
    try {
      archive ??= directory
          ? EpubArchive.directory(sourcePath, digests: digests)
          : EpubArchive.open(sourcePath);
      final opfPath = EpubPackage.readOpfPath(archive);
      final package = EpubPackage.parse(archive, opfPath);
      final mediaTypes = {
        for (final item in package.manifest.values)
          item.entryPath: item.mediaType,
      };
      return EpubSourceReader._(
        archive,
        [for (final item in package.spine) item.entryPath],
        mediaTypes,
        package.uniqueIdentifier,
        opfPath,
        _loadFontDeobfuscator(archive, package),
      );
    } on ImportFailure catch (error) {
      archive?.close();
      throw ContentFailure(
        ContentErrorCode.corrupted,
        '原书结构解析失败：${error.displayText}',
      );
    }
  }

  /// 读 `META-INF/encryption.xml` 建字体解混淆表。
  ///
  /// 没有这个文件（绝大多数书）或文件读不出来时返回空表：字体解混淆失败不该
  /// 拦住阅读，缺字形的表现由 WebView 自己兜底。
  static EpubFontDeobfuscator _loadFontDeobfuscator(
    EpubArchive archive,
    EpubPackage package,
  ) {
    const path = 'META-INF/encryption.xml';
    if (!archive.contains(path)) return EpubFontDeobfuscator.empty;
    try {
      return EpubFontDeobfuscator.parse(
        archive.readText(path),
        opfPath: package.opfPath,
        exists: archive.contains,
      );
    } on ImportFailure {
      return EpubFontDeobfuscator.empty;
    }
  }

  /// 章节数（= spine 条目数）
  int get chapterCount => _entryPaths.length;

  /// 原生直读只接管归档中确实存在的已知资源，其他条目沿用原来的解析路径。
  Map<String, String> get nativeResourceTypes => {
    for (final entry in _mediaTypes.keys)
      if (_archive.contains(entry)) entry: mediaTypeOf(entry),
  };

  /// spine 中第 [ordinal] 章的归档内路径。
  String entryPathAt(int ordinal) => _entryPaths[ordinal];

  /// 归档内是否真的有这个条目。拦截器据此决定放行还是回 404。
  bool containsEntry(String entryPath) => _archive.contains(entryPath);

  /// 以某个条目为基准解析相对引用（CSS 的 `url()`、XHTML 的 `src`/`href`）。
  /// 越界的引用返回 null，调用方按 404 处理。
  String? resolveReference(String baseEntryPath, String href) =>
      resolveEntryPath(baseEntryPath, href);

  /// 读条目字节；条目不存在返回 null（拦截器按 404 处理）。
  ///
  /// 已释放的章节或资源可再次从 ZIP 解压；归档只持有压缩条目的文件索引。
  /// 条目存在但解压失败或超出防护阈值时抛 [ContentFailure]。
  Uint8List? readEntry(String entryPath) {
    if (!_archive.contains(entryPath)) return null;
    try {
      return _archive.readBytes(entryPath);
    } on ImportFailure catch (error) {
      throw ContentFailure(
        ContentErrorCode.corrupted,
        '${error.displayText}：$entryPath',
      );
    }
  }

  /// media-type：优先 OPF manifest，缺失时按扩展名兜底。
  String mediaTypeOf(String entryPath) {
    final declared = _mediaTypes[entryPath];
    if (declared != null && declared.isNotEmpty) return declared;
    return _mediaTypeByExtension(entryPath);
  }

  /// 重置解压总量预算。
  ///
  /// 归档层的总输出上限（1 GiB）是防解压炸弹用的；原书模式在一个会话里
  /// 逐章读资源，长书累计可能触顶。换章时重置一次，预算按「一章 + 它的
  /// 资源」计算仍远低于上限，防护不失效。
  void resetBudget() => _archive.resetTotalBudget();

  /// 关闭底层文件句柄。重复调用安全。
  void close() {
    if (_closed) return;
    _closed = true;
    _archive.close();
  }
}

/// 与数据库章节索引对齐校验。
///
/// 抽出成扩展，让调用点读起来是「源文件对一下索引」而不是一堆循环。
extension EpubSourceVerification on EpubSourceReader {
  /// 校验通过返回 null，否则返回人类可读的不一致描述。
  String? mismatchWith(List<Chapter> chapters) {
    if (chapters.length != chapterCount) {
      return '原书 $chapterCount 章，章节索引 ${chapters.length} 章';
    }
    for (var i = 0; i < chapters.length; i++) {
      final chapter = chapters[i];
      if (chapter.ordinal != i) {
        return '第 ${i + 1} 个章节的 ordinal 是 ${chapter.ordinal}';
      }
      final expected = epubChapterId(i, entryPathAt(i));
      if (chapter.id != expected) {
        return '第 ${i + 1} 章 ID 不匹配（索引 ${chapter.id}，原书 $expected）';
      }
    }
    return null;
  }
}

/// 扩展名 → media-type 兜底表。只覆盖 EPUB 里常见的资源类型。
String _mediaTypeByExtension(String entryPath) {
  final ext = p.extension(entryPath).toLowerCase().replaceFirst('.', '');
  return switch (ext) {
    'xhtml' => 'application/xhtml+xml',
    'html' || 'htm' => 'text/html',
    'css' => 'text/css',
    'png' => 'image/png',
    'jpg' || 'jpeg' => 'image/jpeg',
    'gif' => 'image/gif',
    'webp' => 'image/webp',
    'svg' => 'image/svg+xml',
    'bmp' => 'image/bmp',
    'ttf' => 'font/ttf',
    'otf' => 'font/otf',
    'woff' => 'font/woff',
    'woff2' => 'font/woff2',
    'ncx' => 'application/x-dtbncx+xml',
    'js' => 'text/javascript',
    'mp3' => 'audio/mpeg',
    'mp4' => 'video/mp4',
    _ => 'application/octet-stream',
  };
}
