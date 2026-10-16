/// 章节正文与资源的读取契约（纯 Dart，不引用 Flutter / drift）。
///
/// 路径基准见 `docs/EPUB渲染引擎实现计划.md` 4.5 节：
/// - 章节正文：`Chapter.contentPath` 相对**书籍目录** → `library/<bookId>/content/<版本>/<章>.json`
/// - 正文图片：`ContentBlock.resourcePath` 相对 **content/<版本>/** → `library/<bookId>/content/<版本>/res/...`
/// - 目录：`library/<bookId>/content/<版本>/manifest.json` 的嵌套 `toc`
library;

import '../models/book_document.dart';
import '../services/toc_entry_index.dart';

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
  /// 读取单章正文。实现内部有小容量缓存，按需读取，不整本进内存。
  Future<ChapterContent> chapter(
    String bookId,
    Chapter chapter, {
    bool textOnly = false,
  });

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
