import '../../domain/repositories/app_theme_repository.dart';
import '../database/app_database.dart';

class DriftAppThemeRepository implements AppThemeRepository {
  DriftAppThemeRepository(this.db);
  final AppDatabase db;
  @override
  Future<AppThemeMode> load() async {
    final row = await db.customSelect("SELECT value_json FROM preferences WHERE scope='global' AND scope_id='global' AND key='appTheme'").getSingleOrNull();
    return AppThemeMode.values.firstWhere(
      (mode) => mode.name == row?.read<String>('value_json'),
      orElse: () => AppThemeMode.system,
    );
  }

  @override
  Future<void> save(AppThemeMode mode) => db.customStatement('''INSERT INTO preferences
    (scope,scope_id,key,value_json,schema_version,updated_at) VALUES('global','global','appTheme',?,1,?)
    ON CONFLICT(scope,scope_id,key) DO UPDATE SET value_json=excluded.value_json,updated_at=excluded.updated_at''',
    [mode.name, DateTime.now().toUtc().toIso8601String()]);
}
