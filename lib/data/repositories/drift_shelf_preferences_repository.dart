import 'dart:convert';

import 'package:drift/drift.dart';

import '../../domain/models/shelf_preferences.dart';
import '../../domain/models/shelf_sort.dart';
import '../../domain/repositories/shelf_preferences_repository.dart';
import '../database/app_database.dart';

/// 书架展示偏好存进全局 preferences。
///
/// 排序沿用旧键 `shelfSort`，布局使用新键 `shelfGridView`；老用户第一次
/// 升级时没有布局记录，仍按网格显示。
class DriftShelfPreferencesRepository implements ShelfPreferencesRepository {
  DriftShelfPreferencesRepository(this.db);
  final AppDatabase db;

  static const _sortKey = 'shelfSort';
  static const _gridKey = 'shelfGridView';

  @override
  Future<ShelfPreferences> load() async {
    final rows =
        await (db.select(db.preferences)..where(
              (t) =>
                  t.scope.equals('global') &
                  t.scopeId.equals('global') &
                  t.key.isIn([_sortKey, _gridKey]),
            ))
            .get();
    final values = {for (final row in rows) row.key: row.valueJson};
    return ShelfPreferences(
      sort: _decodeSort(values[_sortKey]),
      gridView: _decodeGridView(values[_gridKey]),
    );
  }

  ShelfSort _decodeSort(String? json) {
    final name = json == null ? null : jsonDecode(json);
    return ShelfSort.values.firstWhere(
      (sort) => sort.name == name,
      orElse: () => ShelfSort.title,
    );
  }

  /// 只认真正保存过的 `false`；没有记录或值不认识时按网格布局。
  bool _decodeGridView(String? json) =>
      json == null ? true : jsonDecode(json) != false;

  @override
  Future<void> saveSort(ShelfSort sort) => _save(_sortKey, sort.name);

  @override
  Future<void> saveGridView(bool gridView) => _save(_gridKey, gridView);

  Future<void> _save(String key, Object value) => db
      .into(db.preferences)
      .insertOnConflictUpdate(
        PreferencesCompanion.insert(
          scope: 'global',
          scopeId: 'global',
          key: key,
          valueJson: jsonEncode(value),
          updatedAt: DateTime.now().toUtc(),
        ),
      );
}
