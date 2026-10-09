import 'dart:convert';

import 'package:drift/drift.dart';

import '../../domain/repositories/statistics_settings_repository.dart';
import '../../domain/rules/achievement_rules.dart';
import '../database/app_database.dart';

class DriftStatisticsSettingsRepository
    implements StatisticsSettingsRepository {
  DriftStatisticsSettingsRepository(this.db);
  final AppDatabase db;
  @override
  Future<StatisticsSettings> load() async {
    final row = await db
        .customSelect(
          "SELECT value_json FROM preferences WHERE scope='global' AND scope_id='global' AND key='statisticsSettings'",
        )
        .getSingleOrNull();
    if (row == null) return const StatisticsSettings();
    final value =
        jsonDecode(row.read<String>('value_json')) as Map<String, dynamic>;
    return StatisticsSettings(
      idleMinutes: [2, 5, 10].contains(value['idleMinutes'])
          ? value['idleMinutes'] as int
          : 5,
      includeAudio: value['includeAudio'] != false,
    );
  }

  @override
  Future<void> save(StatisticsSettings value) => db.customStatement(
    '''INSERT INTO preferences
    (scope,scope_id,key,value_json,schema_version,updated_at) VALUES('global','global','statisticsSettings',?,1,?)
    ON CONFLICT(scope,scope_id,key) DO UPDATE SET value_json=excluded.value_json,updated_at=excluded.updated_at''',
    [
      jsonEncode({
        'idleMinutes': value.idleMinutes,
        'includeAudio': value.includeAudio,
      }),
      DateTime.now().toUtc().toIso8601String(),
    ],
  );

  @override
  Future<void> clearStatistics() async {
    await db.transaction(() async {
      await db.customStatement('DELETE FROM reading_segments');
      await db.customStatement('DELETE FROM reading_sessions');
      await db.customStatement('DELETE FROM daily_stats');
      // 与规则使用同一分类，保留已读书籍奖励，避免硬编码遗漏新增时长成就。
      for (final rule in achievementRules.where(
        (r) => [
          AchievementMetric.time,
          AchievementMetric.streak,
          AchievementMetric.days,
        ].contains(r.metric),
      )) {
        await db.customStatement(
          'DELETE FROM achievements WHERE achievement_id=?',
          [rule.id],
        );
      }
    });
    db.notifyUpdates({const TableUpdate('reading_segments')});
  }
}
