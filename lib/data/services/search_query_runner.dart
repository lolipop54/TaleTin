import '../../domain/models/book_search.dart';
import '../../engine/search/search_text.dart';
import 'search_file_worker.dart';
import 'book_search_source.dart';

/// 后台逐章直接查正文并边查边发布，不读取或建立磁盘搜索索引。
class SearchQueryRunner {
  const SearchQueryRunner(this.source);
  final BookSearchSource source;

  Stream<BookSearchUpdate> run(
    String bookId,
    String query, {
    BookSearchCursor? after,
    int limit = 50,
    required SearchCancellation cancellation,
  }) async* {
    final needle = normalizeSearchQuery(query);
    if (needle.isEmpty || cancellation.cancelled) {
      yield const BookSearchUpdate(BookSearchPage([], null), 0, 0, true);
      return;
    }
    final (book, chapters, revision) = await source.snapshot(bookId);
    final epoch = source.generation(bookId);
    final hits = <BookSearchHit>[];
    final pulse = Stopwatch()..start();
    if (epoch != source.generation(bookId)) throw StateError('正文已经变化，请重新搜索');
    yield BookSearchUpdate(
      BookSearchPage([], after),
      0,
      chapters.length,
      false,
    );
    for (
      var ordinal = after?.chapter ?? 0;
      ordinal < chapters.length;
      ordinal++
    ) {
      if (cancellation.cancelled) return;
      final chapter = chapters[ordinal];
      final matches = await source.work(
        bookId,
        () => cancellation.cancelled
            ? Future.value(<({BookSearchHit hit, int at})>[])
            : searchFileChapter(
                source.contents.chapterAbsolutePath(bookId, chapter),
                chapter.title,
                bookId,
                book.contentVersion,
                needle,
                ordinal == after?.chapter ? after!.offset : 0,
                limit - hits.length + 1,
                '$revision:$epoch',
              ),
      );
      if (cancellation.cancelled) return;
      if (epoch != source.generation(bookId)) throw StateError('正文已经变化，请重新搜索');
      BookSearchCursor? next;
      for (final match in matches) {
        if (hits.length == limit) {
          next = BookSearchCursor(ordinal, match.at);
          break;
        }
        hits.add(match.hit);
      }
      final nextChapter = ordinal + 1;
      next ??= nextChapter < chapters.length
          ? BookSearchCursor(nextChapter, 0)
          : null;
      final finished = hits.length == limit || ordinal == chapters.length - 1;
      if (finished &&
          ((await source.snapshot(bookId)).$3 != revision ||
              epoch != source.generation(bookId))) {
        throw StateError('正文已经变化，请重新搜索');
      }
      // 无匹配时最多每 50ms 报进度；新命中始终立即发布，不等凑满 50 条。
      if (matches.isNotEmpty || finished || pulse.elapsedMilliseconds >= 50) {
        yield BookSearchUpdate(
          BookSearchPage(List.unmodifiable(hits), next),
          next == null
              ? chapters.length
              : next.chapter == ordinal
              ? ordinal
              : nextChapter,
          chapters.length,
          finished,
        );
        pulse.reset();
      }
      if (finished) return;
    }
    if (!cancellation.cancelled) {
      if ((await source.snapshot(bookId)).$3 != revision ||
          epoch != source.generation(bookId)) {
        throw StateError('正文已经变化，请重新搜索');
      }
      yield BookSearchUpdate(
        const BookSearchPage([], null),
        chapters.length,
        chapters.length,
        true,
      );
    }
  }
}
