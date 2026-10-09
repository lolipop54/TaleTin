import '../models/book_group.dart';

abstract interface class BookGroupRepository {
  Future<List<BookGroup>> load();
  Stream<List<BookGroup>> watch();
  Future<BookGroup> create(String name);
  Future<void> delete(String id);
  Future<void> reorder(List<String> ids);
  Future<void> moveBooks(Set<String> bookIds, String? groupId);
}
