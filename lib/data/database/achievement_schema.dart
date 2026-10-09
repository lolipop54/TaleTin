import 'app_database.dart';

Future<void> createAchievementSchema(AppDatabase db) => db.customStatement('''
  CREATE TABLE achievements (
    achievement_id TEXT PRIMARY KEY, rule_version INTEGER NOT NULL,
    unlocked_at TEXT NOT NULL, progress_snapshot INTEGER NOT NULL,
    presented INTEGER NOT NULL DEFAULT 0 CHECK(presented IN (0,1)))''');
