import 'dart:convert';

import '../../domain/repositories/reading_controls_repository.dart';
import '../database/app_database.dart';

class DriftReadingControlsRepository implements ReadingControlsRepository {
  DriftReadingControlsRepository(this.db);
  final AppDatabase db;
  @override
  Future<ReadingControls> load() async {
    final row = await db
        .customSelect(
          "SELECT value_json FROM preferences WHERE scope='global' AND scope_id='global' AND key='readingControls'",
        )
        .getSingleOrNull();
    if (row == null) return const ReadingControls();
    final value =
        jsonDecode(row.read<String>('value_json')) as Map<String, dynamic>;
    return ReadingControls(
      keepAwake: value['keepAwake'] == true,
      volumeKeys: value['volumeKeys'] == true,
      statusBar: value['statusBar'] != false,
      navigationBar: value['navigationBar'] != false,
    );
  }

  @override
  Future<void> save(ReadingControls value) => db.customStatement(
    '''INSERT INTO preferences
    (scope,scope_id,key,value_json,schema_version,updated_at) VALUES('global','global','readingControls',?,1,?)
    ON CONFLICT(scope,scope_id,key) DO UPDATE SET value_json=excluded.value_json,updated_at=excluded.updated_at''',
    [
      jsonEncode({
        'keepAwake': value.keepAwake,
        'volumeKeys': value.volumeKeys,
        'statusBar': value.statusBar,
        'navigationBar': value.navigationBar,
      }),
      DateTime.now().toUtc().toIso8601String(),
    ],
  );
}
