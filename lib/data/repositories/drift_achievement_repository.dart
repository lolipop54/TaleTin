import 'package:drift/drift.dart';

import '../../domain/rules/achievement_rules.dart';
import '../../domain/repositories/achievement_repository.dart';
import '../database/app_database.dart';
import 'drift_reading_statistics_repository.dart';
import 'drift_book_completion_repository.dart';

class DriftAchievementRepository implements AchievementRepository {
  DriftAchievementRepository(this.db);
  final AppDatabase db;
  @override
  Stream<void> get changes => db
      .tableUpdates(
        TableUpdateQuery.allOf([
          const TableUpdateQuery.onTableName('reading_segments'),
          const TableUpdateQuery.onTableName('book_completions'),
        ]),
      )
      .map((_) {});

  @override
  Future<AchievementEvaluation> evaluate({
    bool silently = false,
  }) => db.transaction(() async {
    final ids = achievementRules.map((r) => r.id).toSet();
    // 用户要求清除旧版成就。只删除勋章记录，实际阅读统计和已读记录保留。
    await db.customStatement(
      'DELETE FROM achievements WHERE rule_version < ? OR achievement_id NOT IN (${List.filled(ids.length, '?').join(',')})',
      [achievementRuleVersion, ...ids],
    );
    final stats = await DriftReadingStatisticsRepository(db).load();
    final completions = await DriftBookCompletionRepository(db).load();
    final facts = AchievementFacts(statistics: stats, completions: completions);
    if (silently) {
      await db.customStatement(
        'UPDATE achievements SET presented=1 WHERE presented=0',
      );
    }
    for (final rule in achievementRules) {
      final value = facts.value(rule.metric);
      if (value < rule.target) continue;
      await db.customStatement(
        '''INSERT OR IGNORE INTO achievements
        (achievement_id,rule_version,unlocked_at,progress_snapshot,presented)
        VALUES(?,?,?,?,?)''',
        [
          rule.id,
          rule.version,
          DateTime.now().toUtc().toIso8601String(),
          value,
          silently ? 1 : 0,
        ],
      );
    }
    final rows = await db
        .customSelect(
          'SELECT * FROM achievements ORDER BY unlocked_at,achievement_id',
        )
        .get();
    return AchievementEvaluation(
      facts,
      rows
          .map(
            (r) => AchievementUnlock(
              id: r.read('achievement_id'),
              ruleVersion: r.read('rule_version'),
              unlockedAt: DateTime.parse(r.read('unlocked_at')),
              progressSnapshot: r.read('progress_snapshot'),
              presented: r.read<int>('presented') == 1,
            ),
          )
          .toList(),
    );
  });

  @override
  Future<bool> claim(String id) => db.transaction(() async {
    final changed = await db.customUpdate(
      'UPDATE achievements SET presented=1 WHERE achievement_id=? AND presented=0',
      variables: [Variable.withString(id)],
    );
    return changed == 1;
  });
}
