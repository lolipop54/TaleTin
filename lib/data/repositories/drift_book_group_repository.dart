import 'package:characters/characters.dart';
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
    final groups = await load();
    final group = BookGroup(
      id: const Uuid().v4(),
      name: _validatedName(name, groups),
    );
    await db.customStatement(
      'INSERT INTO book_groups(id, name, sort_order) VALUES (?, ?, ?)',
      [group.id, group.name, groups.length],
    );
    db.notifyUpdates({const TableUpdate('book_groups')});
    return group;
  });

  @override
  Future<BookGroup> rename(String id, String name) => db.transaction(() async {
    final groups = await load();
    final current = groups.firstWhere((group) => group.id == id);
    final trimmed = _validatedName(name, groups, exceptId: id);
    if (trimmed == current.name) return current;
    // 只改名称，书籍归属和分组顺序仍沿用原来的分组 ID。
    await db.customStatement('UPDATE book_groups SET name = ? WHERE id = ?', [
      trimmed,
      id,
    ]);
    db.notifyUpdates({const TableUpdate('book_groups')});
    return BookGroup(id: id, name: trimmed);
  });

  String _validatedName(
    String name,
    List<BookGroup> groups, {
    String? exceptId,
  }) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) throw const FormatException('请输入分组名称');
    if (trimmed.characters.length > 40) {
      throw const FormatException('分组名称最多 40 个字');
    }
    if (const ['全部', '在读', '已读', '未分组'].contains(trimmed)) {
      throw const FormatException('请换一个名称，避免与默认分类重复');
    }
    if (groups.any((g) => g.id != exceptId && g.name == trimmed)) {
      throw const FormatException('已经有同名分组，请换一个名称');
    }
    return trimmed;
  }

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
