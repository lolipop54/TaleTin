import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../app/di/shelf_sort_providers.dart';
import '../../../../domain/models/shelf_sort.dart';

/// 首次读取完成才展示书架，保存成功才发布新的排序。
class ShelfSortController extends AsyncNotifier<ShelfSort> {
  @override
  Future<ShelfSort> build() => ref.watch(shelfSortRepositoryProvider).load();

  Future<void> save(ShelfSort sort) async {
    await ref.read(shelfSortRepositoryProvider).save(sort);
    if (ref.mounted) state = AsyncData(sort);
  }
}

final shelfSortProvider = AsyncNotifierProvider<ShelfSortController, ShelfSort>(
  ShelfSortController.new,
);
