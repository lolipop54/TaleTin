import '../../domain/models/book_search.dart';
import '../../domain/repositories/book_search_repository.dart';
import '../services/book_search_source.dart';
import '../services/search_query_runner.dart';

class DirectBookSearchRepository implements BookSearchRepository {
  const DirectBookSearchRepository(this.source);
  final BookSearchSource source;
  @override
  Future<void Function()> prepareContentChange(String bookId) =>
      source.prepareContentChange(bookId);

  @override
  Future<BookSearchPage> search(
    String bookId,
    String query, {
    BookSearchCursor? after,
    int limit = 50,
    required SearchCancellation cancellation,
  }) async {
    final update = await searchUpdates(
      bookId,
      query,
      after: after,
      limit: limit,
      cancellation: cancellation,
    ).last;
    return cancellation.cancelled
        ? const BookSearchPage([], null)
        : update.page;
  }

  @override
  Stream<BookSearchUpdate> searchUpdates(
    String bookId,
    String query, {
    BookSearchCursor? after,
    int limit = 50,
    required SearchCancellation cancellation,
  }) => SearchQueryRunner(
    source,
  ).run(bookId, query, after: after, limit: limit, cancellation: cancellation);
}
