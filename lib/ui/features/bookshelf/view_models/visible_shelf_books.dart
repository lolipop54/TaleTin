import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/di/app_providers.dart';
import '../../../../core/concurrency/background_compute.dart';
import '../../../../domain/models/book.dart';
import '../../../../domain/services/shelf_books.dart';
import 'bookshelf_view_model.dart';

/// 查询条件相同时，多选、工具栏和布局重建共用已经整理好的列表。
final visibleShelfBooksProvider = FutureProvider<List<Book>>((ref) async {
  final query = ref.watch(bookshelfProvider.select((s) => s.presentationQuery));
  final books = await ref.watch(libraryBooksProvider.future);
  final indices = await backgroundCompute(_sort, (
    books,
    query,
  ), enabled: books.length >= backgroundListThreshold);
  return [for (final index in indices) books[index]];
});

List<int> _sort((List<Book>, ShelfQuery) input) {
  final (books, query) = input;
  final indices = {for (var i = 0; i < books.length; i++) books[i]: i};
  return [for (final book in applyShelfQuery(books, query)) indices[book]!];
}
