/// 书架书籍实体（纯 Dart，不依赖 Flutter / 数据库生成类）。
///
/// 数据库中的 `books` 行经 Mapper 映射为本类后再交给 ViewModel。
library;

/// 支持导入的书籍格式。MOBI 在阶段 6 接入。
enum BookFormat {
  epub('epub', 'EPUB'),
  txt('txt', 'TXT'),
  mobi('mobi', 'MOBI');

  const BookFormat(this.code, this.label);

  /// 数据库存储值
  final String code;

  /// 界面展示名
  final String label;

  static BookFormat? fromCode(String code) {
    for (final f in values) {
      if (f.code == code) return f;
    }
    return null;
  }
}

/// 书籍状态；源文件改变只是核验后的显示状态，不删除原记录。
enum BookStatus {
  preparing('preparing'),
  active('active'),
  removed('removed'),
  contentMissing('contentMissing'),
  sourceChanged('sourceChanged');

  const BookStatus(this.code);
  final String code;

  static BookStatus fromCode(String code) =>
      values.firstWhere((s) => s.code == code, orElse: () => BookStatus.active);
}

/// 书架书籍。
///
/// `contentPath` 与 `coverPath` 都是相对书籍目录的路径，例如
/// `content/1/ch01-ab12.json`、`content/1/res/cover.jpg`，
/// 这样切换正文版本时路径仍然可解释。
class Book {
  const Book({
    required this.id,
    required this.sourceHash,
    required this.title,
    required this.author,
    required this.format,
    required this.importedAt,
    this.groupId,
    this.status = BookStatus.active,
    this.contentVersion = 1,
    this.deletedAt,
    this.sizeBytes = 0,
    this.coverPath,
    this.coverWidth,
    this.coverHeight,
    this.textLength = 0,
    this.chapterCount = 0,
    this.readProgress,
    this.lastReadAt,
    this.sourceFileName,
    this.finished = false,
    this.warnings = const [],
  });

  final String id;

  /// 来源唯一标识：新本地书籍存完整file URI；旧书保留原SHA-256。
  /// 保留历史字段名，避免迁移时改写旧书的身份与阅读记录。
  final String sourceHash;
  String? get localSourcePath => sourceHash.startsWith('file:')
      ? Uri.parse(sourceHash).toFilePath() : null;
  final String title;
  final String author;
  final BookFormat format;

  /// 手动分组 ID；null 表示「未分组」
  final String? groupId;
  final BookStatus status;

  /// 当前生效的正文版本号，对应 `content/<版本>/`
  final int contentVersion;
  final DateTime importedAt;
  final DateTime? deletedAt;

  /// 原始文件字节数
  final int sizeBytes;

  /// 封面相对路径；解析未取到封面时为 null，界面用书名占位
  final String? coverPath;
  final int? coverWidth;
  final int? coverHeight;

  /// 标准化正文文本总长度（UTF-16 code unit），用于全书进度分母
  final int textLength;

  /// 章节数量（书架格子进度按章节粒度展示）
  final int chapterCount;

  /// 阅读进度 0–100，带小数（界面按两位小数格式化）；null 表示未读。
  /// 由阅读位置里存的全书内容比例算出，逐页变化（设计文档 6.3）。
  final double? readProgress;

  /// 最近一次保存阅读位置的时间；未读为null。
  final DateTime? lastReadAt;

  /// 导入时的原文件名；早期未保存的书籍为null。
  final String? sourceFileName;

  /// 是否已读完（阶段 5 由完成记录填充）
  final bool finished;

  /// 导入时的兼容性提示（如「样式表已忽略」）
  final List<String> warnings;

  /// 封面角标文案：已读 / 未读 / 两位小数百分比
  String get flagLabel {
    if (finished) return '已读';
    final p = readProgress;
    return p == null ? '未读' : '${p.toStringAsFixed(2)}%';
  }

  /// 源文件扩展名（用于 `source.<ext>` 命名）
  String get sourceExtension => format.code;

  Book copyWith({
    String? title,
    String? author,
    String? groupId,
    bool clearGroup = false,
    BookStatus? status,
    int? contentVersion,
    DateTime? deletedAt,
    bool clearDeletedAt = false,
    int? sizeBytes,
    String? coverPath,
    int? coverWidth,
    int? coverHeight,
    int? textLength,
    int? chapterCount,
    double? readProgress,
    DateTime? lastReadAt,
    String? sourceFileName,
    bool? finished,
    List<String>? warnings,
  }) {
    return Book(
      id: id,
      sourceHash: sourceHash,
      title: title ?? this.title,
      author: author ?? this.author,
      format: format,
      groupId: clearGroup ? null : (groupId ?? this.groupId),
      status: status ?? this.status,
      contentVersion: contentVersion ?? this.contentVersion,
      importedAt: importedAt,
      deletedAt: clearDeletedAt ? null : (deletedAt ?? this.deletedAt),
      sizeBytes: sizeBytes ?? this.sizeBytes,
      coverPath: coverPath ?? this.coverPath,
      coverWidth: coverWidth ?? this.coverWidth,
      coverHeight: coverHeight ?? this.coverHeight,
      textLength: textLength ?? this.textLength,
      chapterCount: chapterCount ?? this.chapterCount,
      readProgress: readProgress ?? this.readProgress,
      lastReadAt: lastReadAt ?? this.lastReadAt,
      sourceFileName: sourceFileName ?? this.sourceFileName,
      finished: finished ?? this.finished,
      warnings: warnings ?? this.warnings,
    );
  }
}
