import '../../domain/models/annotation.dart';
import '../../domain/models/book.dart';
import '../../domain/models/book_document.dart';
import '../../domain/models/locator.dart';
import '../../domain/repositories/book_repository.dart';
import '../../domain/repositories/chapter_content_repository.dart';
import '../../engine/normalization/locator_mapper.dart';
import '../../engine/normalization/source_position_matcher.dart';

import 'dart:convert';

import '../../engine/selection/selection_range.dart';

class AnnotationLocationFailure implements Exception {
  const AnnotationLocationFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 先核对同版本稳定位置；旧版本逐章匹配摘录及上下文，不按比例猜位置。
class AnnotationLocatorService {
  const AnnotationLocatorService(this.books, this.contents, {this.readChapter});
  final BookRepository books;
  final ChapterContentRepository contents;
  final Future<ChapterContent> Function(String, Chapter)? readChapter;
  Future<ChapterContent> _read(String id, Chapter chapter) =>
      readChapter?.call(id, chapter) ??
      contents.chapter(id, chapter, textOnly: true);

  Future<Annotation> resolve(Annotation note) async {
    final book = await books.findById(note.bookId);
    if (book == null || book.status != BookStatus.active) {
      throw const AnnotationLocationFailure('原书不可用，笔记仍保留，请重新导入原文件');
    }
    if (note.start.bookId != book.id || note.end?.bookId != book.id) {
      throw const AnnotationLocationFailure('这条笔记的位置不完整，无法准确定位');
    }
    final chapters = await books.chaptersOf(book.id);
    var start = await _stable(book, chapters, note.start);
    var end = await _stable(book, chapters, note.end!);
    if (start == null || end == null) {
      final matcher = SourcePositionMatcher([
        if (start == null) note.start,
        if (end == null) note.end!,
      ]);
      // 每次只读一章，不为重新定位把整本书常驻内存。
      for (final chapter in chapters) {
        final content = await _read(book.id, chapter);
        matcher.add(chapter.id, content.blocks);
      }
      final found = matcher.finish();
      if (matcher.hasAmbiguous) {
        throw const AnnotationLocationFailure('原文有重复位置，无法准确定位，笔记已保留');
      }
      start ??= found[jsonEncode(note.start.toJson())];
      end ??= found[jsonEncode(note.end!.toJson())];
    }
    if (start == null || end == null) {
      throw const AnnotationLocationFailure('正文已变化，无法准确定位，笔记已保留');
    }
    final rangeContents = <String, ChapterContent>{};
    final from = chapters.indexWhere((c) => c.id == start!.chapterId);
    final to = chapters.indexWhere((c) => c.id == end!.chapterId);
    if (from < 0 || to < from) {
      throw const AnnotationLocationFailure('选段顺序已变化，无法准确定位，笔记已保留');
    }
    for (var i = from; i <= to; i++) {
      rangeContents[chapters[i].id] = await _read(book.id, chapters[i]);
    }
    final resolved = resolveSelection(
      selection: SelectionRange(start: start, end: end),
      chapters: chapters,
      contentOf: (id) => rangeContents[id]!,
    );
    if (_quote(resolved.quote) != _quote(note.quote)) {
      throw const AnnotationLocationFailure('选段内容已变化，无法准确定位，笔记已保留');
    }
    return note.copyWith(start: resolved.range.start, end: resolved.range.end);
  }

  Future<Locator?> _stable(
    Book book,
    List<Chapter> chapters,
    Locator locator,
  ) async {
    if (locator.needsRelocation ||
        locator.contentVersion != book.contentVersion) {
      return null;
    }
    final index = chapters.indexWhere((c) => c.id == locator.chapterId);
    if (index < 0) return null;
    final content = await _read(book.id, chapters[index]);
    for (final block in content.blocks) {
      if (block.id != locator.blockId) continue;
      final text = blockTextOf(block);
      if (locator.utf16Offset < 0 ||
          locator.utf16Offset > text.length ||
          snapToGrapheme(text, locator.utf16Offset) != locator.utf16Offset) {
        return null;
      }
      return _mapper(book, content).at(block, locator.utf16Offset);
    }
    return null;
  }

  LocatorMapper _mapper(Book book, ChapterContent content) => LocatorMapper(
    bookId: book.id,
    contentVersion: book.contentVersion,
    chapterId: content.chapterId,
  );
  String _quote(String text) => text.replaceAll(RegExp(r'\s+'), ' ').trim();
}
