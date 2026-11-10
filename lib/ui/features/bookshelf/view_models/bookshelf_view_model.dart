import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../domain/services/shelf_books.dart';

import '../../../../domain/models/book.dart';
import '../../../../domain/models/shelf_sort.dart';
import 'shelf_preferences_controller.dart';
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
    this.savingLayout = false,
    this.query = '',
    this.gridView = true,
    this.selectedIds = const <String>{},
    this.selectionMode = false,
  });

  final ShelfFilter filter;
  final String? groupId;
  final ShelfSort sort;
  final bool savingSort;

  /// 布局设置正在写库，菜单里的布局选项暂时不可点。
  final bool savingLayout;
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
    bool? savingLayout,
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
      savingLayout: savingLayout ?? this.savingLayout,
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
    ref.listen(shelfPreferencesProvider, (_, next) {
      // 偏好读出来或保存成功后，界面才跟着改排序／布局。
      if (next.hasValue) {
        state = state.copyWith(
          sort: next.requireValue.sort,
          gridView: next.requireValue.gridView,
        );
      }
    });
    // 已提前读好时直接用保存值；还没读好则先按默认值建状态，
    // 书架页会停留在加载态，直到偏好准备好再显示。
    final saved = ref.read(shelfPreferencesProvider).value;
    return BookshelfState(
      sort: saved?.sort ?? ShelfSort.title,
      gridView: saved?.gridView ?? true,
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
      await ref.read(shelfPreferencesProvider.notifier).saveSort(sort);
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

  /// 切换网格／列表布局。
  ///
  /// 先把布局写进 preferences，成功后才发布；杀进程重进应用时
  /// 仍是用户最后选的布局。写库失败会抛出，由菜单提示并保持原布局。
  Future<void> setGridView(bool gridView) async {
    if (state.savingLayout || state.gridView == gridView) return;
    state = state.copyWith(savingLayout: true);
    try {
      await ref.read(shelfPreferencesProvider.notifier).saveGridView(gridView);
    } finally {
      if (ref.mounted) state = state.copyWith(savingLayout: false);
    }
  }

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
