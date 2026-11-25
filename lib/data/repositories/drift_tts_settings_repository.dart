import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';

import '../../domain/models/tts_settings.dart';
import '../../domain/repositories/tts_settings_repository.dart';
import '../database/app_database.dart';

class DriftTtsSettingsRepository implements TtsSettingsRepository {
  DriftTtsSettingsRepository(this.database, {bool? windows})
    : windows = windows ?? Platform.isWindows;
  final AppDatabase database;
  final bool windows;
  static const _shared = 'ttsSettings';
  static const _windowsVoice = 'windowsTtsVoice';

  SimpleSelectStatement<$PreferencesTable, PreferenceRow> get _rows =>
      database.select(database.preferences)..where(
        (row) =>
            row.scope.equals('global') &
            row.scopeId.equals('global') &
            row.key.isIn(windows ? [_shared, _windowsVoice] : [_shared]),
      );

  @override
  Future<TtsSettings> load() async => _settings(await _rows.get());

  @override
  Stream<TtsSettings> watch() => _rows.watch().map(_settings);

  TtsSettings _settings(List<PreferenceRow> rows) {
    final values = {
      for (final row in rows)
        row.key: jsonDecode(row.valueJson) as Map<String, Object?>,
    };
    final shared = values[_shared] ?? const {};
    if (!windows) return TtsSettings.fromJson(shared);
    return TtsSettings.fromJson({
      ...?values[_windowsVoice],
      'speed': shared['speed'],
    });
  }

  @override
  Future<void> save(TtsSettings settings) => database.transaction(() async {
    final shared = settings.toJson();
    if (windows) {
      // 旧备份中的音色属于 Android。两端共用语速，往返恢复也保留另一端的音色。
      await _write(_windowsVoice, {...shared}..remove('speed'));
      final old =
          await (database.select(database.preferences)..where(
                (row) =>
                    row.scope.equals('global') &
                    row.scopeId.equals('global') &
                    row.key.equals(_shared),
              ))
              .getSingleOrNull();
      await _write(_shared, {
        if (old != null) ...jsonDecode(old.valueJson) as Map<String, Object?>,
        'schemaVersion': 1,
        'speed': settings.speed,
      });
    } else {
      await _write(_shared, shared);
    }
  });

  Future<void> _write(String key, Map<String, Object?> value) => database
      .into(database.preferences)
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
