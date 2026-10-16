/// 应用数据库：连接、schema 版本与迁移。
///
/// 日期以 ISO-8601 文本存储并保留毫秒（设计文档 3.1），所有时间写 UTC。
/// 迁移一律手写，不用「删库重建」代替（设计文档 7.1）。
library;

import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';

import 'tables.dart';
import 'statistics_schema.dart';
import 'completion_schema.dart';
import 'achievement_schema.dart';
import 'book_group_schema.dart';

part 'app_database.g.dart';

@DriftDatabase(
  tables: [
    Books,
    Chapters,
    ImportJobs,
    Preferences,
    ReadingPositions,
    Annotations,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.executor);

  /// 日期以 ISO-8601 文本存储并保留毫秒，便于直接查看与跨时区排查
  /// （设计文档 3.1）。所有时间由上层按 UTC 写入。
  @override
  DriftDatabaseOptions get options =>
      const DriftDatabaseOptions(storeDateTimeAsText: true);

  /// 打开应用私有目录下的数据库文件。
  ///
  /// 使用后台 isolate 执行 SQL，避免导入/统计等写操作阻塞界面
  /// （设计文档 3.1：事务与关系查询交给数据库）。
  AppDatabase.openFile(File file)
    : super(NativeDatabase.createInBackground(file));

  /// 内存库：仅用于单元测试与临时校验。
  AppDatabase.memory() : super(NativeDatabase.memory());

  static const currentSchemaVersion = 8;

  @override
  int get schemaVersion => currentSchemaVersion;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      await m.createAll();
      await createStatisticsSchema(this);
      await createCompletionSchema(this);
      await createAchievementSchema(this);
      await createBookGroupSchema(this);
    },
    onUpgrade: (m, from, to) async {
      if (from < 2) {
        // v1 → v2：阅读设置、阅读位置与标注（设计文档 7.1）。
        // 三张表一次建好，老库只迁移一次；这里建的表用的是**当前**定义，
        // 已经带上了后续版本补的列，所以下面不再重复加。
        await m.createTable(preferences);
        await m.createTable(readingPositions);
        await m.createTable(annotations);
        // createTable 不管索引，索引要单独建
        await m.createIndex(idxAnnotationsBookKind);
      }
      if (from >= 2 && from < 3) {
        // v2 → v3：补一列「全书进度」，书架进度直接读它（逐页变化）。
        await m.addColumn(readingPositions, readingPositions.progress);
      }
      if (from >= 2 && from < 4) {
        // v3 → v4：标注补「章节标题快照」和「最后修改时间」，并给
        // 「按书 + 类型」的查询加索引（设计文档 7.1）。
        // 加列只能带默认值，老行的 updated_at 会落成当前时间，
        // 紧接着按 created_at 回填，让老书签看起来没被改过。
        await m.addColumn(annotations, annotations.chapterTitle);
        await m.addColumn(annotations, annotations.updatedAt);
        await customStatement('UPDATE annotations SET updated_at = created_at');
        await m.createIndex(idxAnnotationsBookKind);
      }
      if (from < 5) await createStatisticsSchema(this);
      if (from < 6) await createCompletionSchema(this);
      if (from < 7) await createAchievementSchema(this);
      if (from < 8) await createBookGroupSchema(this);
    },
    beforeOpen: (details) async {
      // 章节随书籍级联删除依赖外键约束
      await customStatement('PRAGMA foreign_keys = ON');
    },
  );
}
