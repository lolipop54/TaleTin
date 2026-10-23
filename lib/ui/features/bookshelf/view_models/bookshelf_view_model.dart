import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../domain/services/shelf_books.dart';

import '../../../../domain/models/book.dart';
import '../../../../domain/models/shelf_sort.dart';
import 'shelf_sort_controller.dart';
export '../../../../domain/models/shelf_sort.dart';

/// 书架视图状态：筛选、搜索、排序、视图模式与多选。
///
/// 数据本身来自 `libraryBooksProvider`（数据库流），本状态只负责
/// 「怎么呈现」，不再持有样例书籍。
class BookshelfState {
  const BookshelfState({
    this.filter = ShelfFilter.all,
    this.groupId,
    this.sort = ShelfSort.title,
    this.savingSort = false,
    this.query = '',
    this.gridView = true,
    this.selectedIds = const <String>{},
    this.selectionMode = false,
  });

  final ShelfFilter filter;
  final String? groupId;
  final ShelfSort sort;
  final bool savingSort;
  final String query;
  final bool gridView;

  /// 空选择仍保留多选面板，只有完成或系统返回退出。
  final Set<String> selectedIds;

  /// 是否处于多选模式
  final bool selectionMode;

  BookshelfState copyWith({
    ShelfFilter? filter,
    String? groupId,
    bool clearGroup = false,
    ShelfSort? sort,
    bool? savingSort,
    String? query,
    bool? gridView,
    Set<String>? selectedIds,
    bool? selectionMode,
  }) {
    return BookshelfState(
      filter: filter ?? this.filter,
      groupId: clearGroup ? null : groupId ?? this.groupId,
      sort: sort ?? this.sort,
      savingSort: savingSort ?? this.savingSort,
      query: query ?? this.query,
      gridView: gridView ?? this.gridView,
      selectedIds: selectedIds ?? this.selectedIds,
      selectionMode: selectionMode ?? this.selectionMode,
    );
  }

  /// 按筛选、搜索与排序整理书架列表。
  ///
  /// 进度与完成状态在阶段 3/5 接入真实数据，当前「在读」按有进度
  /// 但未完成判断，未接入时归入「全部」。
  List<Book> apply(List<Book> books) =>
      applyShelfQuery(books, presentationQuery);

  ShelfQuery get presentationQuery =>
      (filter: filter, groupId: groupId, sort: sort, text: query);

  /// 排序方式的界面文案。
  String get sortLabel => switch (sort) {
    ShelfSort.title => '按文件名',
    ShelfSort.imported => '按导入时间',
    ShelfSort.recent => '按最近阅读',
  };
}

class BookshelfViewModel extends Notifier<BookshelfState> {
  @override
  BookshelfState build() {
    ref.listen(shelfSortProvider, (_, next) {
      if (next.hasValue) state = state.copyWith(sort: next.requireValue);
    });
    return BookshelfState(
      sort: ref.read(shelfSortProvider).value ?? ShelfSort.title,
    );
  }

  void setFilter(ShelfFilter filter) =>
      state = state.copyWith(filter: filter, clearGroup: true);

  void setGroup(String id) =>
      state = state.copyWith(filter: ShelfFilter.all, groupId: id);

  Future<void> setSort(ShelfSort sort) async {
    if (state.savingSort) return;
    state = state.copyWith(savingSort: true);
    try {
      await ref.read(shelfSortProvider.notifier).save(sort);
    } finally {
      if (ref.mounted) state = state.copyWith(savingSort: false);
    }
  }

  /// 在三种排序之间循环切换（点击排序入口）
  Future<void> cycleSort() {
    final next = switch (state.sort) {
      ShelfSort.title => ShelfSort.imported,
      ShelfSort.imported => ShelfSort.recent,
      ShelfSort.recent => ShelfSort.title,
    };
    return setSort(next);
  }

  void setQuery(String query) => state = state.copyWith(query: query);

  void toggleViewMode() => state = state.copyWith(gridView: !state.gridView);

  /// 长按书籍：进入多选模式并选中这一本。
  void beginSelection(String bookId) {
    state = state.copyWith(
      selectionMode: true,
      selectedIds: {...state.selectedIds, bookId},
    );
  }

  /// 取消最后一本也不退出，方便继续选书。
  void toggleSelection(String bookId) {
    final selected = {...state.selectedIds};
    if (!selected.remove(bookId)) selected.add(bookId);
    state = state.copyWith(selectedIds: selected);
  }

  /// 全选当前列表；已全选时清空选择。
  void toggleSelectAll(Iterable<String> visibleIds) {
    final ids = visibleIds.toSet();
    final allSelected = ids.isNotEmpty && state.selectedIds.containsAll(ids);
    state = state.copyWith(selectedIds: allSelected ? const {} : ids);
  }

  /// 退出多选模式。
  void clearSelection() =>
      state = state.copyWith(selectionMode: false, selectedIds: const {});

  /// 删除完成后同步选择集合（去掉已经不存在的书籍）。
  void pruneSelection(Iterable<String> existingIds) {
    final existing = existingIds.toSet();
    state = state.copyWith(
      selectedIds: {
        for (final id in state.selectedIds)
          if (existing.contains(id)) id,
      },
    );
  }
}

final bookshelfProvider = NotifierProvider<BookshelfViewModel, BookshelfState>(
  BookshelfViewModel.new,
);
