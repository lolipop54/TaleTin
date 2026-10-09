import '../models/book_completion.dart';

abstract interface class BookCompletionRepository {
  Future<List<BookCompletion>> load();
  Stream<List<BookCompletion>> watch();
  Future<void> mark(String bookId, String title, CompletionSource source);
  Future<void> revoke(String bookId);
}
