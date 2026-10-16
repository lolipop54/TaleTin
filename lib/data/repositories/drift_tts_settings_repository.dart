import 'dart:convert';

import 'package:drift/drift.dart';

import '../../domain/models/tts_settings.dart';
import '../../domain/repositories/tts_settings_repository.dart';
import '../database/app_database.dart';

class DriftTtsSettingsRepository implements TtsSettingsRepository {
  DriftTtsSettingsRepository(this.database);
  final AppDatabase database;

  @override
  Future<TtsSettings> load() => watch().first;

  @override
  Stream<TtsSettings> watch() =>
      (database.select(database.preferences)..where(
            (t) =>
                t.scope.equals('global') &
                t.scopeId.equals('global') &
                t.key.equals('ttsSettings'),
          ))
          .watchSingleOrNull()
          .map(
            (row) => row == null
                ? const TtsSettings()
                : TtsSettings.fromJson(
                    jsonDecode(row.valueJson) as Map<String, Object?>,
                  ),
          );

  @override
  Future<void> save(TtsSettings settings) async {
    await database
        .into(database.preferences)
        .insertOnConflictUpdate(
          PreferencesCompanion.insert(
            scope: 'global',
            scopeId: 'global',
            key: 'ttsSettings',
            valueJson: jsonEncode(settings.toJson()),
            updatedAt: DateTime.now().toUtc(),
          ),
        );
  }
}
