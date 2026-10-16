/// 数据库表定义。
///
/// 阶段 2 只建了书籍、章节、导入任务 journal 三张表；阅读设置、阅读位置与
/// 标注在 S10/S11（v2 迁移）一次补齐（设计文档 7.1）。
/// 时间统一存 UTC 的 ISO 文本（见 `AppDatabase` 的 `storeDateTimeAsText`）。
library;

import 'package:drift/drift.dart';

/// 书籍表（设计文档 7.1）。
///
/// `sourceHash` 唯一：按原始文件 SHA-256 去重；墓碑删除（status=removed）
/// 的行保留，重新导入同哈希文件时复用原 bookId 重新激活。
@DataClassName('BookRow')
class Books extends Table {
  TextColumn get id => text()();

  TextColumn get sourceHash => text().unique()();

  TextColumn get title => text()();

  TextColumn get author => text().withDefault(const Constant(''))();

  /// epub / txt / mobi
  TextColumn get format => text()();

  /// 手动分组；null 为「未分组」
  TextColumn get groupId => text().nullable()();

  /// active / removed / contentMissing
  TextColumn get status => text().withDefault(const Constant('active'))();

  /// 当前生效的正文版本号，对应 content/<版本>/
  IntColumn get contentVersion => integer().withDefault(const Constant(1))();

  DateTimeColumn get importedAt => dateTime()();

  DateTimeColumn get deletedAt => dateTime().nullable()();

  /// 原始文件字节数
  IntColumn get sizeBytes => integer().withDefault(const Constant(0))();

  /// 封面相对路径（相对书籍目录），null 表示无封面
  TextColumn get coverPath => text().nullable()();

  IntColumn get coverWidth => integer().nullable()();

  IntColumn get coverHeight => integer().nullable()();

  /// 标准化正文总长度（UTF-16 code unit）
  IntColumn get textLength => integer().withDefault(const Constant(0))();

  IntColumn get chapterCount => integer().withDefault(const Constant(0))();

  /// 导入时的兼容性提示（JSON 字符串数组）
  TextColumn get warningsJson => text().withDefault(const Constant('[]'))();

  @override
  Set<Column> get primaryKey => {id};
}

/// 章节表：章节 ID 只在文档内稳定，主键为 `bookId + id`。
@DataClassName('ChapterRow')
class Chapters extends Table {
  TextColumn get id => text()();

  TextColumn get bookId =>
      text().references(Books, #id, onDelete: KeyAction.cascade)();

  /// 阅读顺序，从 0 开始
  IntColumn get ordinal => integer()();

  TextColumn get title => text()();

  /// 相对书籍目录的章节文件路径，形如 content/1/ch001-ab12.json
  TextColumn get contentPath => text()();

  /// 章节正文长度（UTF-16 code unit）
  IntColumn get textLength => integer().withDefault(const Constant(0))();

  /// EPUB 原始 href（可选适配信息）
  TextColumn get href => text().nullable()();

  @override
  Set<Column> get primaryKey => {bookId, id};

  @override
  List<Set<Column>> get uniqueKeys => [
        {bookId, ordinal},
      ];
}

/// 导入任务 journal（设计文档 7.1）。
///
/// 文件移动与数据库事务不是同一事务，用本表记录导入阶段，
/// 启动时据此回收孤儿文件、清理残留暂存目录。
@DataClassName('ImportJobRow')
class ImportJobs extends Table {
  TextColumn get id => text()();

  /// picked / copying / parsing / committing / done / failed / cancelled
  TextColumn get stage => text()();

  /// 暂存目录（`cache/import/<jobId>`）
  TextColumn get stagingPath => text().nullable()();

  /// 解析成功后将要写入的书籍 ID
  TextColumn get targetBookId => text().nullable()();

  /// 失败错误码（ImportErrorCode）
  TextColumn get errorCode => text().nullable()();

  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

/// 阅读偏好（设计文档 7.1）：全局默认值与单书覆盖都是 key/value JSON。
///
/// `scope = global` 时 `scopeId` 固定为 `global`；`scope = book` 时为 bookId。
/// 这样做的好处是「单书覆盖 > 全局默认 > 内置默认」的合并完全在读取侧完成，
/// 全局值变化不会覆盖单书已经写过的项（设计文档 2.3）。
@DataClassName('PreferenceRow')
class Preferences extends Table {
  /// global / book
  TextColumn get scope => text()();

  /// global 或 bookId
  TextColumn get scopeId => text()();

  /// 偏好键：typography / readingTheme
  TextColumn get key => text()();

  /// 值的 JSON 文本
  TextColumn get valueJson => text()();

  /// 写入时的数据格式版本，便于以后改写 JSON 结构时做迁移
  IntColumn get schemaVersion => integer().withDefault(const Constant(1))();

  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {scope, scopeId, key};
}

/// 阅读位置（设计文档 7.1）：一本书一行，退出/暂停时写入，启动时恢复。
@DataClassName('ReadingPositionRow')
class ReadingPositions extends Table {
  TextColumn get bookId =>
      text().references(Books, #id, onDelete: KeyAction.cascade)();

  /// Locator 的 JSON（章节 + 块 + 块内偏移 + 摘录，设计文档 4.5 节口径）
  TextColumn get locatorJson => text()();

  /// 全书进度 0–1（内容比例，与排版无关）：书架直接用它显示百分比。
  RealColumn get progress => real().nullable()();

  DateTimeColumn get updatedAt => dateTime()();

  IntColumn get schemaVersion => integer().withDefault(const Constant(1))();

  @override
  Set<Column> get primaryKey => {bookId};
}

/// 标注（设计文档 7.1）：书签、高亮、笔记共用一张表。
///
/// 书签只用 `startLocator`（不选区）；高亮与笔记两端都写。
@DataClassName('AnnotationRow')
@TableIndex(name: 'idxAnnotationsBookKind', columns: {#bookId, #kind})
class Annotations extends Table {
  TextColumn get id => text()();

  TextColumn get bookId =>
      text().references(Books, #id, onDelete: KeyAction.cascade)();

  /// bookmark / highlight / note
  TextColumn get kind => text()();

  TextColumn get startLocatorJson => text()();

  TextColumn get endLocatorJson => text().nullable()();

  /// 摘录原文（书签用于列表展示；高亮与笔记用于回看）
  TextColumn get quote => text().withDefault(const Constant(''))();

  /// 笔记正文（kind = note 时有值）
  TextColumn get body => text().withDefault(const Constant(''))();

  /// 高亮颜色 Token
  TextColumn get colorToken => text().nullable()();

  /// 章节标题快照：书被移除后章节索引一起删掉，笔记列表靠它显示写在哪儿。
  /// 老数据没有这一列，读出为空串。
  TextColumn get chapterTitle => text().withDefault(const Constant(''))();

  DateTimeColumn get createdAt => dateTime()();

  /// 最后修改时间：改想法或换颜色要能在列表里体现。写入方显式给值。
  ///
  /// 可空是为了迁移：SQLite 不允许 `ADD COLUMN` 带非常量默认值，
  /// 老库只能先加一列空的，再按 `createdAt` 回填（见 `AppDatabase.migration`）。
  DateTimeColumn get updatedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}
