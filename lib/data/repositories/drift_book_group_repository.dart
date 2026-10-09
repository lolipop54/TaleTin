import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../domain/models/book_group.dart';
import '../../domain/repositories/book_group_repository.dart';
import '../database/app_database.dart';

class DriftBookGroupRepository implements BookGroupRepository {
  DriftBookGroupRepository(this.db);
  final AppDatabase db;

  @override
  Future<List<BookGroup>> load() async => [
    for (final row
        in await db
            .customSelect(
              'SELECT id, name FROM book_groups ORDER BY sort_order, id',
            )
            .get())
      BookGroup(id: row.read<String>('id'), name: row.read<String>('name')),
  ];

  @override
  Stream<List<BookGroup>> watch() async* {
    yield await load();
    yield* db
        .tableUpdates(const TableUpdateQuery.onTableName('book_groups'))
        .asyncMap((_) => load());
  }

  @override
  Future<BookGroup> create(String name) => db.transaction(() async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) throw const FormatException('请输入分组名称');
    if (trimmed.length > 40) throw const FormatException('分组名称最多 40 个字');
    if (const ['全部', '在读', '已读', '未分组'].contains(trimmed)) {
      throw const FormatException('请换一个名称，避免与默认分类重复');
    }
    final groups = await load();
    if (groups.any((g) => g.name == trimmed)) {
      throw const FormatException('已经有同名分组，请换一个名称');
    }
    final group = BookGroup(id: const Uuid().v4(), name: trimmed);
    await db.customStatement(
      'INSERT INTO book_groups(id, name, sort_order) VALUES (?, ?, ?)',
      [group.id, group.name, groups.length],
    );
    db.notifyUpdates({const TableUpdate('book_groups')});
    return group;
  });

  @override
  Future<void> delete(String id) => db.transaction(() async {
    // 同一事务解除关联并删组，保留书籍、正文、笔记和阅读记录。
    await (db.update(db.books)..where((b) => b.groupId.equals(id))).write(
      const BooksCompanion(groupId: Value(null)),
    );
    await db.customStatement('DELETE FROM book_groups WHERE id = ?', [id]);
    // 补齐顺序空位，后续新建分组仍可靠地追加到末尾。
    await reorder((await load()).map((g) => g.id).toList());
  });

  @override
  Future<void> reorder(List<String> ids) => db.transaction(() async {
    // 一次提交整个顺序，数据库监听者不会看见只改了一半的排列。
    for (var i = 0; i < ids.length; i++) {
      await db.customStatement(
        'UPDATE book_groups SET sort_order = ? WHERE id = ?',
        [i, ids[i]],
      );
    }
    db.notifyUpdates({const TableUpdate('book_groups')});
  });

  @override
  Future<void> moveBooks(Set<String> bookIds, String? groupId) async {
    await (db.update(db.books)..where((b) => b.id.isIn(bookIds))).write(
      BooksCompanion(groupId: Value(groupId)),
    );
  }
}
