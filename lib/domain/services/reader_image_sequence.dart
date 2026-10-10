import '../models/book.dart';
import '../models/book_document.dart';
import '../models/locator.dart';
import '../repositories/chapter_content_repository.dart';

class ReaderImageEntry {
  const ReaderImageEntry(this.locator, this.path);
  final Locator locator;
  final String path;
}

class ReaderImageSequence {
  const ReaderImageSequence(this.images, this.initialIndex);
  final List<ReaderImageEntry> images;
  final int initialIndex;
}

/// 从点击图片向两侧找连续图片，遇到正文文字即停止；允许跨章节。
/// 只读取块索引，图片本身在查看时逐张解码，不整本漫画载入内存。
/// [currentOnly] 只定位当前图，供窗口先打开；相邻图片随后在后台查找。
Future<ReaderImageSequence?> readerImageSequence({
  required ChapterContentRepository contents,
  required Book book,
  required List<Chapter> chapters,
  required String chapterId,
  required String resourcePath,
  String? blockId,
  bool currentOnly = false,
  bool Function()? isActive,
}) async {
  bool active() => isActive?.call() ?? true;
  if (!active()) return null;
  final startChapter = chapters.indexWhere((c) => c.id == chapterId);
  if (startChapter < 0) return null;
  // 查图片顺序只需已保存的块号与路径，不补表格、SVG尺寸或重读源EPUB。
  final content = await contents.chapter(
    book.id,
    chapters[startChapter],
    textOnly: true,
  );
  if (!active()) return null;
  final start = content.blocks.indexWhere(
    (b) =>
        b.kind == BlockKind.image &&
        (blockId != null ? b.id == blockId : b.resourcePath == resourcePath),
  );
  if (start < 0) return null;
  ReaderImageEntry entry(ContentBlock block, int index) => ReaderImageEntry(
    Locator(
      bookId: book.id,
      contentVersion: book.contentVersion,
      chapterId: chapters[index].id,
      blockId: block.id,
      utf16Offset: 0,
      affinity: LocatorAffinity.before,
      resourceHref: chapters[index].href,
    ),
    contents.resourceAbsolutePath(
      book.id,
      book.contentVersion,
      block.resourcePath!,
    ),
  );

  final current = entry(content.blocks[start], startChapter);
  if (currentOnly) return ReaderImageSequence([current], 0);

  Future<List<ReaderImageEntry>> walk(int direction) async {
    final found = <ReaderImageEntry>[];
    var chapterIndex = startChapter, blockIndex = start + direction;
    var blocks = content.blocks;
    var visited = 0;
    while (active()) {
      // 命中内存中的长章节时也让出执行机会，图片绘制和关闭点击不会被遍历挤住。
      if (++visited % 200 == 0) {
        await Future<void>.delayed(Duration.zero);
        if (!active()) break;
      }
      if (blockIndex < 0 || blockIndex >= blocks.length) {
        chapterIndex += direction;
        if (chapterIndex < 0 || chapterIndex >= chapters.length) break;
        blocks = (await contents.chapter(
          book.id,
          chapters[chapterIndex],
          textOnly: true,
        )).blocks;
        if (!active()) break;
        blockIndex = direction > 0 ? 0 : blocks.length - 1;
        continue;
      }
      final block = blocks[blockIndex];
      if (block.runs.any((run) => run.text.trim().isNotEmpty)) break;
      if (block.kind == BlockKind.image && block.resourcePath != null) {
        found.add(entry(block, chapterIndex));
      }
      blockIndex += direction;
    }
    return found;
  }

  final before = await walk(-1);
  if (!active()) return null;
  final after = await walk(1);
  if (!active()) return null;
  return ReaderImageSequence([
    ...before.reversed,
    current,
    ...after,
  ], before.length);
}
