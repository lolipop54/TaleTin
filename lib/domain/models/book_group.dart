/// 用户新建的书架分组；未分组由 books.groupId == null 表示。
class BookGroup {
  const BookGroup({required this.id, required this.name});
  final String id;
  final String name;
}
