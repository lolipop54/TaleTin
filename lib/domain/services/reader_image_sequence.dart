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
Future<ReaderImageSequence?> readerImageSequence({
  required ChapterContentRepository contents,
  required Book book,
  required List<Chapter> chapters,
  required String chapterId,
  required String resourcePath,
  String? blockId,
}) async {
  final startChapter = chapters.indexWhere((c) => c.id == chapterId);
  if (startChapter < 0) return null;
  final content = await contents.chapter(book.id, chapters[startChapter]);
  final start = content.blocks.indexWhere((b) => b.kind == BlockKind.image &&
    (blockId != null ? b.id == blockId : b.resourcePath == resourcePath));
  if (start < 0) return null;
  ReaderImageEntry entry(ContentBlock block, int index) => ReaderImageEntry(
    Locator(bookId: book.id, contentVersion: book.contentVersion,
      chapterId: chapters[index].id, blockId: block.id, utf16Offset: 0,
      affinity: LocatorAffinity.before, resourceHref: chapters[index].href),
    contents.resourceAbsolutePath(book.id, book.contentVersion, block.resourcePath!));

  Future<List<ReaderImageEntry>> walk(int direction) async {
    final found = <ReaderImageEntry>[];
    var chapterIndex = startChapter, blockIndex = start + direction;
    var blocks = content.blocks;
    while (true) {
      if (blockIndex < 0 || blockIndex >= blocks.length) {
        chapterIndex += direction;
        if (chapterIndex < 0 || chapterIndex >= chapters.length) break;
        blocks = (await contents.chapter(book.id, chapters[chapterIndex])).blocks;
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
  final before = await walk(-1), after = await walk(1);
  return ReaderImageSequence([
    ...before.reversed, entry(content.blocks[start], startChapter), ...after,
  ], before.length);
}
