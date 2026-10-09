import '../../../domain/models/locator.dart';
import '../../../domain/repositories/book_repository.dart';
import '../../../domain/repositories/chapter_content_repository.dart';
import '../../../domain/repositories/reading_position_repository.dart';
import '../../../domain/services/book_progress.dart';
import '../../../engine/normalization/text_anchor.dart';

/// 使用既有仓库的章节缓存，不加载整书正文、不依赖阅读页布局。
class ListeningProgress {
  ListeningProgress(this.books, this.contents);
  final BookRepository books;
  final ChapterContentRepository contents;

  Future<ReadingPosition> resolve(Locator locator) async {
    final book = await books.findById(locator.bookId);
    if (book == null || book.contentVersion != locator.contentVersion) {
      throw StateError('听书正文版本已变化');
    }
    final chapters = await books.chaptersOf(book.id);
    final index = chapters.indexWhere((c) => c.id == locator.chapterId);
    if (index < 0) throw StateError('听书章节已不存在');
    final content = await contents.chapter(book.id, chapters[index]);
    return ReadingPosition(
      locator: locator,
      source: ReadingPositionSource.listening,
      progress: bookProgressAt(
        chapters,
        book.textLength,
        index,
        fractionOfLocator(
          content: content,
          bookId: book.id,
          contentVersion: book.contentVersion,
          chapterId: locator.chapterId,
          locator: locator,
        ),
      ),
    );
  }
}
