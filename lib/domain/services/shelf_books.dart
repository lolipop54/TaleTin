import 'package:lpinyin/lpinyin.dart';

import '../models/book.dart';
import '../models/shelf_sort.dart';

/// 只包含决定列表内容的条件，多选和网格切换不触发排序。
typedef ShelfQuery = ({
  ShelfFilter filter,
  String? groupId,
  ShelfSort sort,
  String text,
});
final _names = <String, String>{};
final _searchFields = <String, (String, String, String, String)>{};

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

List<Book> applyShelfQuery(List<Book> books, ShelfQuery query) {
  final ids = <String>{}, namesInUse = <String>{};
  for (final book in books) {
    ids.add(book.id);
    namesInUse.add(book.sourceFileName ?? book.title);
    final previous = _searchFields[book.id];
    if (previous == null ||
        previous.$1 != book.title ||
        previous.$2 != book.author) {
      _searchFields[book.id] = (
        book.title,
        book.author,
        book.title.toLowerCase(),
        book.author.toLowerCase(),
      );
    }
  }
  // 只保留当前书库使用的字段；删书、恢复后不会积攒历史书名。
  _names.removeWhere((name, _) => !namesInUse.contains(name));
  _searchFields.removeWhere((id, _) => !ids.contains(id));
  Iterable<Book> result = books;
  if (query.groupId != null) {
    result = result.where((b) => b.groupId == query.groupId);
  }
  switch (query.filter) {
    case ShelfFilter.all:
      break;
    case ShelfFilter.ungrouped:
      result = result.where((b) => b.groupId == null);
    case ShelfFilter.reading:
      result = result.where((b) => !b.finished && b.readProgress != null);
    case ShelfFilter.finished:
      result = result.where((b) => b.finished);
  }
  final q = query.text.trim().toLowerCase();
  if (q.isNotEmpty) {
    result = result.where(
      (b) =>
          _searchFields[b.id]!.$3.contains(q) ||
          _searchFields[b.id]!.$4.contains(q),
    );
  }
  final list = result.toList();
  // 每个文件名在本轮只转换一次；同步完成排序后再交给界面显示。
  final names = _names;
  String nameKey(Book book) {
    final name = book.sourceFileName ?? book.title;
    return names.putIfAbsent(name, () => _fileNameSortKey(name));
  }

  int byName(Book a, Book b) => nameKey(a).compareTo(nameKey(b));
  list.sort((a, b) {
    final order = switch (query.sort) {
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
