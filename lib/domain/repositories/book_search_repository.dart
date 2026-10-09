import '../models/book_search.dart';

abstract class BookSearchRepository {
  /// 后台逐章直接查正文，按正文顺序即时发布本批命中。
  Stream<BookSearchUpdate> searchUpdates(
    String bookId,
    String query, {
    BookSearchCursor? after,
    int limit = 50,
    required SearchCancellation cancellation,
  });
  Future<BookSearchPage> search(
    String bookId,
    String query, {
    BookSearchCursor? after,
    int limit = 50,
    required SearchCancellation cancellation,
  });

  /// 文件变更前作废旧搜索并等待读取收尾，调用者在 finally 释放暂停。
  Future<void Function()> prepareContentChange(String bookId);
}
