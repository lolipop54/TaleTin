import '../models/shelf_sort.dart';

abstract interface class ShelfSortRepository {
  Future<ShelfSort> load();
  Future<void> save(ShelfSort sort);
}
