import 'package:drift/drift.dart';

import '../../domain/repositories/listening_timer_repository.dart';
import '../database/app_database.dart';

class DriftListeningTimerRepository implements ListeningTimerRepository {
  DriftListeningTimerRepository(this.database);
  final AppDatabase database;
  @override
  Future<int?> loadMinutes() async {
    final row =
        await (database.select(database.preferences)..where(
              (t) =>
                  t.scope.equals('global') &
                  t.scopeId.equals('global') &
                  t.key.equals('listeningTimerMinutes'),
            ))
            .getSingleOrNull();
    return row == null ? null : int.parse(row.valueJson);
  }

  @override
  Future<void> saveMinutes(int minutes) => database
      .into(database.preferences)
      .insertOnConflictUpdate(
        PreferencesCompanion.insert(
          scope: 'global',
          scopeId: 'global',
          key: 'listeningTimerMinutes',
          valueJson: '$minutes',
          updatedAt: DateTime.now().toUtc(),
        ),
      );
}
