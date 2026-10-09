import 'dart:convert';
import 'package:drift/drift.dart';

import '../../domain/models/shelf_sort.dart';
import '../../domain/repositories/shelf_sort_repository.dart';
import '../database/app_database.dart';

class DriftShelfSortRepository implements ShelfSortRepository {
  DriftShelfSortRepository(this.db);
  final AppDatabase db;

  @override
  Future<ShelfSort> load() async {
    final row = await (db.select(db.preferences)..where((t) =>
      t.scope.equals('global') & t.scopeId.equals('global') &
      t.key.equals('shelfSort'))).getSingleOrNull();
    final name = row == null ? null : jsonDecode(row.valueJson);
    return ShelfSort.values.firstWhere((sort) => sort.name == name,
      orElse: () => ShelfSort.title);
  }

  @override
  Future<void> save(ShelfSort sort) => db.into(db.preferences).insertOnConflictUpdate(
    PreferencesCompanion.insert(scope: 'global', scopeId: 'global', key: 'shelfSort',
      valueJson: jsonEncode(sort.name), updatedAt: DateTime.now().toUtc()),
  );
}
