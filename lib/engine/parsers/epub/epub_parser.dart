/// EPUB 解析适配器：输出与 TXT 相同的 [BookDocument]。
///
/// 流程：容器 → OPF → 目录（nav / NCX）→ 逐章 XHTML 转块 → 封面与资源落盘
/// → 章节文件与目录树（设计文档 6.1/6.2）。
///
/// 产物全部写入 [ParseRequest.workDir]（提交前的暂存目录），不触碰书架。
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import '../../../core/errors/import_error.dart';
import '../../../domain/models/book_document.dart';
import '../../../domain/services/book_parser.dart';
import 'epub_archive.dart';
import 'epub_package.dart';
import 'epub_source_reader.dart';
import 'image_sniff.dart';
import 'xhtml_blocks.dart';

class EpubParser {
  const EpubParser();

  /// 兼容性提示：写入清单并直接展示给读者
  static const String warningContainer = '文件容器不完全符合 EPUB 规范';
  static const String warningNoToc = '未找到目录，已按正文顺序平铺章节';

  /// 固定版式（漫画类多见）：不是重排书，只能按单页图片顺排显示
  static const String warningFixedLayout = '固定版式书籍，按单页图片顺排显示';

  /// 书名取文件名（去掉扩展名），不用 OPF 里的 `dc:title`。
  ///
  /// 依据（2026-09-20）：`dc:title` 由制作工具写入，实测见过书名号只写一半的
  /// （例如文件名叫《骑士的血脉》（实体精校版）.epub，元数据却是「骑士的血脉》（实体精校版）」），
  /// 显示出来就是个落单的书名号。文件名是用户自己给的那份，更可控。
  /// 仅当文件名取不出内容时才退回元数据。
  static String _titleFromFileName(String displayName, String metaTitle) {
    final name = p.basenameWithoutExtension(displayName).trim();
    return name.isEmpty ? metaTitle : name;
  }

  Future<BookDocument> parse(
    ParseRequest request, {
    required ParseProgress onProgress,
    required bool Function() isCancelled,
    ParseCover? onCover,
  }) async {
    final archive = EpubArchive.open(request.sourcePath);
    try {
      final opfPath = EpubPackage.readOpfPath(archive);
      final package = EpubPackage.parse(archive, opfPath);
      final workDir = request.workDir;
      final resourceDir = p.join(workDir, 'res');

      final warnings = <String>{};
      if (!_mimetypeLooksValid(archive)) warnings.add(warningContainer);
      // 固定版式（漫画类）不做重排，只按单页图片顺排：先说清楚，别让读者
      // 以为是排版出错（设计文档 6.2 格式兼容矩阵）
      if (package.fixedLayout) warnings.add(warningFixedLayout);

      // 归档内图片的 media-type，用于过滤 img 指向的非图片资源
      final mediaTypes = {
        for (final item in package.manifest.values)
          item.entryPath: item.mediaType,
      };
      final imageCache = <String, ResolvedImage>{};

      ResolvedImage? resolveImage(String entryPath) {
        final cached = imageCache[entryPath];
        if (cached != null) return cached;
        final mediaType = mediaTypes[entryPath];
        if (mediaType != null &&
            !mediaType.startsWith('image/') &&
            !entryPath.toLowerCase().endsWith('.svg')) {
          return null;
        }
        if (!archive.contains(entryPath)) return null;
        final bytes = archive.readBytes(entryPath);
        final size = sniffImageSize(bytes);
        final target = p.join(resourceDir, entryPath);
        File(target).parent.createSync(recursive: true);
        File(target).writeAsBytesSync(bytes, flush: false);
        final resolved = ResolvedImage(
          resourcePath: 'res/$entryPath',
          width: size.width,
          height: size.height,
        );
        imageCache[entryPath] = resolved;
        return resolved;
      }

      // 先发布封面，再处理正文；字节随任务回传，不依赖稍后移动的暂存路径。
      final coverItem = package.coverItem;
      final cover = coverItem == null ? null : resolveImage(coverItem.entryPath);
      if (cover != null) {
        onCover?.call(File(p.join(workDir, cover.resourcePath)).readAsBytesSync());
      }

      // 目录先行：章节标题优先取目录标题
      final tocTitles = <String, String>{};
      final navigationDocuments = <String, String>{};
      final rawToc = _readRawToc(
        archive, package, tocTitles, navigationDocuments: navigationDocuments,
      );
      if (rawToc.isEmpty) warnings.add(warningNoToc);

      final chapters = <Chapter>[];
      final tocNodes = <TocNode>[];
      final spineHrefs = <String, String>{};
      final total = package.spine.length;
      for (var index = 0; index < total; index++) {
        if (isCancelled()) throw const ImportFailure(ImportErrorCode.cancelled);
        final item = package.spine[index];
        final chapterId = epubChapterId(index, item.entryPath);
        spineHrefs[item.entryPath] = chapterId;

        final builder = XhtmlBlockBuilder(
          basePath: item.entryPath,
          resolveImage: resolveImage,
        );
        final result = builder.convert(
          navigationDocuments.remove(item.entryPath) ?? archive.readText(item.entryPath),
        );
        warnings.addAll(result.warnings);

        final title = _chapterTitle(
          tocTitles[item.entryPath],
          result,
          package.coverItem?.entryPath,
        );
        final content = ChapterContent(
          chapterId: chapterId,
          blocks: result.blocks,
          tables: result.tables,
        );
        final contentPath = 'content/${request.contentVersion}/$chapterId.json';
        File(p.join(workDir, '$chapterId.json'))
            .writeAsBytesSync(content.encode(), flush: false);
        chapters.add(
          Chapter(
            id: chapterId,
            ordinal: index,
            title: title,
            contentPath: contentPath,
            textLength: content.textLength,
            href: item.href,
          ),
        );
        onProgress(0.1 + 0.85 * ((index + 1) / total));
      }

      if (chapters.isEmpty) {
        throw const ImportFailure(ImportErrorCode.emptyContent);
      }

      tocNodes.addAll(_buildToc(rawToc, spineHrefs, chapters));

      final metaTitle = _titleFromFileName(request.displayName, package.title);
      final metaAuthor = package.author;
      onProgress(1);
      return BookDocument(
        title: metaTitle,
        author: metaAuthor,
        contentVersion: request.contentVersion,
        chapters: chapters,
        toc: tocNodes,
        coverPath: cover?.resourcePath,
        coverWidth: cover?.width,
        coverHeight: cover?.height,
        warnings: warnings.toList(),
      );
    } finally {
      archive.close();
    }
  }

  /// 无标题页不编造章号；只在正文确实使用封面资源时标为封面。
  static String _chapterTitle(
    String? tocTitle,
    XhtmlBlocks result,
    String? coverPath,
  ) {
    final title = tocTitle?.trim().isNotEmpty == true
        ? tocTitle
        : result.headingTitle;
    if (title != null && title.trim().isNotEmpty) return title;
    final isCover =
        coverPath != null &&
        result.blocks.length == 1 &&
        result.blocks.single.kind == BlockKind.image &&
        result.blocks.single.resourcePath == 'res/$coverPath';
    return isCover ? '封面' : '';
  }

  /// 旧索引未记录标题来源，仅对旧默认章号回查源书，保留真实同名标题。
  static Map<String, String> resolveLegacyTitles(
    String sourcePath,
    List<Chapter> candidates,
  ) {
    final archive = EpubArchive.open(sourcePath);
    try {
      final package = EpubPackage.parse(
        archive,
        EpubPackage.readOpfPath(archive),
      );
      final titles = <String, String>{};
      final navigationDocuments = <String, String>{};
      const EpubParser()._readRawToc(
        archive, package, titles, navigationDocuments: navigationDocuments,
      );
      return {
        for (final chapter in candidates)
          chapter.id: (() {
            final item = package.spine[chapter.ordinal];
            final result = XhtmlBlockBuilder(
              basePath: item.entryPath,
              resolveImage: (path) =>
                  ResolvedImage(resourcePath: 'res/$path', width: 1, height: 1),
            ).convert(
              navigationDocuments.remove(item.entryPath) ?? archive.readText(item.entryPath),
            );
            return _chapterTitle(
              titles[item.entryPath],
              result,
              package.coverItem?.entryPath,
            );
          })(),
      };
    } finally {
      archive.close();
    }
  }

  /// 从源 EPUB 重新读取目录，供旧导入数据修复使用。
  /// 只重建目录树，不改章节 ID、正文与阅读位置。
  static List<TocNode> resolveLegacyToc(
    String sourcePath,
    List<Chapter> chapters,
  ) {
    final archive = EpubArchive.open(sourcePath);
    try {
      final package = EpubPackage.parse(
        archive,
        EpubPackage.readOpfPath(archive),
      );
      final raw = const EpubParser()._readRawToc(archive, package, {});
      // 旧章节保存的是 OPF 相对 href，NCX 解析后则是归档内完整路径。
      final idsByHref = {
        for (final c in chapters)
          if (c.href != null) c.href!: c.id,
      };
      final hrefs = <String, String>{};
      for (final item in package.spine) {
        final id = idsByHref[item.href];
        if (id != null) hrefs[item.entryPath] = id;
      }
      return const EpubParser()._buildToc(raw, hrefs, chapters);
    } finally {
      archive.close();
    }
  }

  /// 读取目录：优先 EPUB3 nav，其次 NCX；同时收集 href→标题。
  List<RawTocEntry> _readRawToc(
    EpubArchive archive,
    EpubPackage package,
    Map<String, String> titles, {
    Map<String, String>? navigationDocuments,
  }) {
    List<RawTocEntry> entries = const [];
    final navItem = package.navItem;
    if (navItem != null && archive.contains(navItem.entryPath)) {
      final source = archive.readText(navItem.entryPath);
      // 有些书把 nav 目录页也列入正文；归档条目只读一次，正文复用后释放。
      if (package.spine.any((item) => item.entryPath == navItem.entryPath)) {
        navigationDocuments?[navItem.entryPath] = source;
      }
      entries = parseNavDocument(
        source,
        navItem.entryPath,
      );
    }
    if (entries.isEmpty) {
      final ncxItem = package.ncxItem;
      if (ncxItem != null && archive.contains(ncxItem.entryPath)) {
        entries = parseNcxDocument(
          archive.readText(ncxItem.entryPath),
          ncxItem.entryPath,
        );
      }
    }
    _collectTitles(entries, titles);
    return entries;
  }

  void _collectTitles(List<RawTocEntry> entries, Map<String, String> titles) {
    for (final entry in entries) {
      final href = entry.href;
      if (href != null) titles.putIfAbsent(href, () => entry.title);
      _collectTitles(entry.children, titles);
    }
  }

  /// 原始目录 → 嵌套 TocNode；扁平 NCX（只列册名）按 spine 范围合成子目录。
  List<TocNode> _buildToc(
    List<RawTocEntry> raw,
    Map<String, String> spineHrefs,
    List<Chapter> chapters,
  ) {
    final indexOfChapter = {for (final c in chapters) c.id: c.ordinal};

    List<TocNode> mapEntries(List<RawTocEntry> entries) {
      final nodes = <TocNode>[];
      for (final entry in entries) {
        final chapterId = entry.href == null ? null : spineHrefs[entry.href];
        final children = mapEntries(entry.children);
        if (chapterId == null && children.isEmpty) continue;
        nodes.add(
          TocNode(
            title: entry.title,
            chapterId: chapterId,
            fragment: entry.fragment,
            children: children,
          ),
        );
      }
      return nodes;
    }

    var nodes = mapEntries(raw);
    if (nodes.isEmpty) {
      return [
        for (final c in chapters) TocNode(title: c.title, chapterId: c.id),
      ];
    }

    // 全部是叶子且数量少于章节数：目录只列了卷册，按 spine 范围补出子目录
    final allLeaves = nodes.every((n) => n.children.isEmpty && n.isLeaf);
    if (allLeaves && nodes.length < chapters.length) {
      final grouped = <TocNode>[];
      for (var i = 0; i < nodes.length; i++) {
        final start = indexOfChapter[nodes[i].chapterId] ?? 0;
        final end = i + 1 < nodes.length
            ? (indexOfChapter[nodes[i + 1].chapterId] ?? chapters.length)
            : chapters.length;
        final children = <TocNode>[
          for (
            var index = start;
            index < end && index < chapters.length;
            index++
          )
            TocNode(
              title: chapters[index].title,
              chapterId: chapters[index].id,
            ),
        ];
        grouped.add(TocNode(title: nodes[i].title, children: children));
      }
      nodes = grouped;
    }
    return nodes;
  }

  /// 容器宽松探测：mimetype 缺失、非首条目或被压缩时提示，但不拒绝导入。
  bool _mimetypeLooksValid(EpubArchive archive) {
    final entry = archive.find('mimetype');
    if (entry == null) return false;
    if (entry.isCompressed) return false;
    try {
      return archive.readText('mimetype').trim() == 'application/epub+zip';
    } catch (_) {
      return false;
    }
  }
}
