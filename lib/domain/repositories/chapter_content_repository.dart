/// 章节正文与资源的读取契约（纯 Dart，不引用 Flutter / drift）。
///
/// 路径基准见 `docs/EPUB引擎与直接阅读260921-261013/EPUB渲染引擎实现计划.md` 4.5 节：
/// - 章节正文：`Chapter.contentPath` 相对**书籍目录** → `library/<bookId>/content/<版本>/<章>.json`
/// - 正文图片：`ContentBlock.resourcePath` 相对 **content/<版本>/** → `library/<bookId>/content/<版本>/res/...`
/// - 目录：`library/<bookId>/content/<版本>/manifest.json` 的嵌套 `toc`
library;

import 'dart:typed_data';

import '../models/book_document.dart';
import '../models/locator.dart';
import '../services/toc_entry_index.dart';
import '../services/txt_chapter_sections.dart';

typedef TocLocations = ({
  Map<String, Map<String, double?>> anchors,
  Map<String, Map<String, double>> headings,
});

/// 正文读取失败。
///
/// 只区分「文件不见了」与「内容读不出来」两类：前者是书被外部删除或导入不全，
/// 后者是文件损坏。界面据此给出不同文案与重试入口（设计文档 9.7）。
enum ContentErrorCode { missing, corrupted, sourceChanged }

class ContentFailure implements Exception {
  const ContentFailure(this.code, this.detail);

  final ContentErrorCode code;
  final String detail;

  String get message => switch (code) {
    ContentErrorCode.missing => '正文文件缺失，请重新导入这本书',
    ContentErrorCode.corrupted => '正文文件损坏，无法打开这一章',
    ContentErrorCode.sourceChanged => '源文件已改变',
  };

  @override
  String toString() => 'ContentFailure(${code.name}: $detail)';
}

abstract class ChapterContentRepository {
  /// 文件仓库可在后台把逐章读取和匹配放在一起，避免整章文字往返界面。
  /// 内存替身保持原有逐章接口；null 表示没有专门的后台实现。
  Future<Map<String, Locator?>?> matchSourcePositions(
    String bookId,
    List<Chapter> chapters,
    List<Locator> anchors,
  ) async => null;

  /// 读取单章正文。实现内部有小容量缓存，按需读取，不整本进内存。
  Future<ChapterContent> chapter(
    String bookId,
    Chapter chapter, {
    bool textOnly = false,
  });

  /// 有磁盘缓存的仓库核验来源后优先读图，其他仓库沿用按页渲染。
  Future<Uint8List> pdfThumbnail(
    String bookId,
    Chapter page,
    int width,
    Future<Uint8List> Function() render,
  ) async {
    await chapter(bookId, page, textOnly: true);
    return render();
  }

  /// 简化分页需要正文的精确排版摘要。文件仓库可复用写缓存的字节。
  Future<ChapterContent> chapterForProgressLayout(
    String bookId,
    Chapter chapter,
  ) => this.chapter(bookId, chapter);

  /// 有可靠的小节字节位置时，简化分页可以按节读取。旧格式仍按章读取。
  Future<TxtChapterSource?> txtChapterSource(
    String bookId,
    Chapter chapter,
  ) async => null;

  /// 阅读窗口持有的章节不参与图片回收；空列表释放该窗口的保护。
  /// 文件仓库只登记已有/即将生成的资料，不在这里渲染邻页。
  Future<void> retainReadingChapters(
    String bookId,
    Object owner,
    List<Chapter> chapters,
  ) async {}

  /// 目录位置是可重建资料；内存仓库可直接使用默认的无缓存实现。
  Future<List<TocProgressEntry>?> readTocProgress(
    String bookId,
    String signature,
  ) async => null;
  Future<void> writeTocProgress(
    String bookId,
    String signature,
    List<TocProgressEntry> entries,
  ) async {}

  /// 读取嵌套目录（`manifest.json`）；没有目录时返回空列表，界面降级为平铺。
  Future<List<TocNode>> toc(String bookId, int contentVersion);

  /// 目录的可展开小节。调用方只传入需要分节的 TXT 章节。
  Future<Map<String, List<TxtTocSection>>> txtTocSections(
    String bookId,
    List<Chapter> chapters,
  ) async => {
    for (final entry in chapters)
      entry.id: TxtChapterSections.tocOf(
        await chapter(bookId, entry, textOnly: true),
      ),
  };

  /// Small locations from the same manifest as the TOC. The reading session has
  /// already verified its current source before preparing progress titles.
  Future<TocLocations?> tocLocations(String bookId, int contentVersion) async =>
      null;

  /// 拼出正文图片的绝对路径。
  ///
  /// [resourcePath] 是 `ContentBlock.resourcePath`（形如 `res/OEBPS/Images/p1.jpg`），
  /// 相对 `content/<版本>/`。同步方法，便于界面在 build 中直接使用。
  String resourceAbsolutePath(
    String bookId,
    int contentVersion,
    String resourcePath,
  );

  /// 拼出章节正文文件的绝对路径（调试与自检用）。
  String chapterAbsolutePath(String bookId, Chapter chapter);

  /// 丢弃缓存（书籍被删除或重新导入后调用）。
  void invalidate([String? bookId]);
}
