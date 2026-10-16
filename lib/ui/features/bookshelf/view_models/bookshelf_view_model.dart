import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lpinyin/lpinyin.dart';

import '../../../../domain/models/book.dart';
import '../../../../domain/models/shelf_sort.dart';
import 'shelf_sort_controller.dart';
export '../../../../domain/models/shelf_sort.dart';

/// 字母（含中文拼音）排在前面，其余首字符统一归入末尾的 #。
/// 不跳过书名号、数字或空白，避免改变原文件名首字符的含义。
String _fileNameSortKey(String name) {
  final pinyin = PinyinHelper.getPinyinE(
    name,
    separator: '',
    defPinyin: '#',
  ).toLowerCase();
  final first = pinyin.isEmpty ? 0 : pinyin.codeUnitAt(0);
  final group = first >= 97 && first <= 122 ? '0' : '1';
  return '$group$pinyin';
}

/// 书架筛选：全部 / 在读 / 已读 / 未分组
enum ShelfFilter { all, reading, finished, ungrouped }

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
  });

  final ShelfFilter filter;
  final String? groupId;
  final ShelfSort sort;
  final bool savingSort;
  final String query;
  final bool gridView;

  /// 多选模式下已选中的书籍 ID；空集合同时也表示「不在多选模式」，
  /// 因此进入多选模式时至少要选中一本。
  final Set<String> selectedIds;

  /// 是否处于多选模式
  bool get selectionMode => selectedIds.isNotEmpty;

  BookshelfState copyWith({
    ShelfFilter? filter,
    String? groupId,
    bool clearGroup = false,
    ShelfSort? sort,
    bool? savingSort,
    String? query,
    bool? gridView,
    Set<String>? selectedIds,
  }) {
    return BookshelfState(
      filter: filter ?? this.filter,
      groupId: clearGroup ? null : groupId ?? this.groupId,
      sort: sort ?? this.sort,
      savingSort: savingSort ?? this.savingSort,
      query: query ?? this.query,
      gridView: gridView ?? this.gridView,
      selectedIds: selectedIds ?? this.selectedIds,
    );
  }

  /// 按筛选、搜索与排序整理书架列表。
  ///
  /// 进度与完成状态在阶段 3/5 接入真实数据，当前「在读」按有进度
  /// 但未完成判断，未接入时归入「全部」。
  List<Book> apply(List<Book> books) {
    Iterable<Book> result = books;
    if (groupId != null) result = result.where((b) => b.groupId == groupId);
    switch (filter) {
      case ShelfFilter.all:
        break;
      case ShelfFilter.ungrouped:
        result = result.where((b) => b.groupId == null);
      case ShelfFilter.reading:
        result = result.where((b) => !b.finished && b.readProgress != null);
      case ShelfFilter.finished:
        result = result.where((b) => b.finished);
    }
    final q = query.trim().toLowerCase();
    if (q.isNotEmpty) {
      result = result.where(
        (b) => b.title.toLowerCase().contains(q) || b.author.toLowerCase().contains(q),
      );
    }
    final list = result.toList();
    // 每个文件名在本轮只转换一次；同步完成排序后再交给界面显示。
    final names = <String, String>{};
    String nameKey(Book book) {
      final name = book.sourceFileName ?? book.title;
      return names.putIfAbsent(name, () => _fileNameSortKey(name));
    }

    int byName(Book a, Book b) => nameKey(a).compareTo(nameKey(b));
    list.sort((a, b) {
      final order = switch (sort) {
        ShelfSort.title => byName(a, b),
        ShelfSort.imported => b.importedAt.compareTo(a.importedAt),
        ShelfSort.recent =>
          a.lastReadAt == null
              ? (b.lastReadAt == null ? 0 : 1)
              : b.lastReadAt == null
              ? -1
              : b.lastReadAt!.compareTo(a.lastReadAt!),
      };
      // 批量导入时间可能相同，增加固定次序，刷新时不会随机换位。
      if (order != 0) return order;
      final imported = b.importedAt.compareTo(a.importedAt);
      if (imported != 0) return imported;
      final name = byName(a, b);
      return name != 0 ? name : a.id.compareTo(b.id);
    });
    return list;
  }

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
    state = state.copyWith(selectedIds: {...state.selectedIds, bookId});
  }

  /// 多选模式下点书籍：切换选中状态；取消最后一个选中即退出多选模式。
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
  void clearSelection() => state = state.copyWith(selectedIds: const {});

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
