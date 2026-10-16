/// 持久阅读位置（设计文档 6.3）。
///
/// 页码只是某次排版的临时结果，不能拿来当唯一进度：这里存的是**内容锚点**——
/// 章 + 块 + 块内 UTF-16 偏移，配一段摘录与前后文，重新分页后用它们重新定位。
/// `epubCfi`、`resourceHref` 只是格式适配信息，阅读逻辑不依赖它们。
library;

/// 图片块与切分边界用到的定位倾向。
enum LocatorAffinity {
  /// 贴在目标位置之前（图片块的上沿）
  before(-1),

  /// 默认：文本偏移处
  center(0),

  /// 贴在目标位置之后（图片块的下沿）
  after(1);

  const LocatorAffinity(this.value);

  /// 落盘/传参用的稳定值
  final int value;

  static LocatorAffinity fromValue(int value) => switch (value) {
        -1 => LocatorAffinity.before,
        1 => LocatorAffinity.after,
        _ => LocatorAffinity.center,
      };
}

/// 摘录与前后文的长度上限：够重新定位即可，不把整段抄进进度记录。
const int kLocatorExactLimit = 32;
const int kLocatorContextLimit = 16;

class Locator {
  const Locator({
    required this.bookId,
    required this.contentVersion,
    required this.chapterId,
    required this.blockId,
    required this.utf16Offset,
    this.affinity = LocatorAffinity.center,
    this.exact = '',
    this.prefix = '',
    this.suffix = '',
    this.resourceHref,
    this.epubCfi,
    this.needsRelocation = false,
    this.imageResource,
  });

  final String bookId;

  /// 正文规范化规则版本；源文件改变另由 needsRelocation 标记，不能只比较此值。
  final int contentVersion;
  final String chapterId;
  final String blockId;

  /// 块内标准化文本的 UTF-16 code unit 偏移，必须落在字素簇边界
  final int utf16Offset;
  final LocatorAffinity affinity;

  /// 摘录（用于重解析后的重新定位）
  final String exact;
  final String prefix;
  final String suffix;

  /// EPUB 专属适配信息（可选，阅读逻辑不依赖）
  final String? resourceHref;
  final String? epubCfi;

  /// 源文件已换内容，旧块号不能再直接用于显示或跳转。
  final bool needsRelocation;
  /// 图片在标准正文中的资源路径；不与 EPUB 的章节路径混用。
  final String? imageResource;

  Locator copyWith({
    String? chapterId,
    String? blockId,
    int? utf16Offset,
    LocatorAffinity? affinity,
    String? exact,
    String? prefix,
    String? suffix,
    bool? needsRelocation,
    String? imageResource,
  }) =>
      Locator(
        bookId: bookId,
        contentVersion: contentVersion,
        chapterId: chapterId ?? this.chapterId,
        blockId: blockId ?? this.blockId,
        utf16Offset: utf16Offset ?? this.utf16Offset,
        affinity: affinity ?? this.affinity,
        exact: exact ?? this.exact,
        prefix: prefix ?? this.prefix,
        suffix: suffix ?? this.suffix,
        resourceHref: resourceHref,
        epubCfi: epubCfi,
        needsRelocation: needsRelocation ?? this.needsRelocation,
        imageResource: imageResource ?? this.imageResource,
      );

  Map<String, Object?> toJson() => {
        'bookId': bookId,
        'contentVersion': contentVersion,
        'chapterId': chapterId,
        'blockId': blockId,
        'utf16Offset': utf16Offset,
        if (affinity != LocatorAffinity.center) 'affinity': affinity.value,
        if (exact.isNotEmpty) 'exact': exact,
        if (prefix.isNotEmpty) 'prefix': prefix,
        if (suffix.isNotEmpty) 'suffix': suffix,
        if (resourceHref != null) 'resourceHref': resourceHref,
        if (epubCfi != null) 'epubCfi': epubCfi,
        if (needsRelocation) 'needsRelocation': true,
        if (imageResource != null) 'imageResource': imageResource,
      };

  static Locator fromJson(Map<String, Object?> json) => Locator(
        bookId: json['bookId'] as String? ?? '',
        contentVersion: (json['contentVersion'] as num?)?.toInt() ?? 1,
        chapterId: json['chapterId'] as String? ?? '',
        blockId: json['blockId'] as String? ?? '',
        utf16Offset: (json['utf16Offset'] as num?)?.toInt() ?? 0,
        affinity: LocatorAffinity.fromValue(
          (json['affinity'] as num?)?.toInt() ?? 0,
        ),
        exact: json['exact'] as String? ?? '',
        prefix: json['prefix'] as String? ?? '',
        suffix: json['suffix'] as String? ?? '',
        resourceHref: json['resourceHref'] as String?,
        epubCfi: json['epubCfi'] as String?,
        needsRelocation: json['needsRelocation'] == true,
        imageResource: json['imageResource'] as String?,
      );

  /// 同一个内容位置的判定口径：章节 + 块 + 偏移 + 倾向。
  ///
  /// 摘录与上下文不参与相等判断，它们只是重新定位时的旁证。
  bool samePosition(Locator other) =>
      bookId == other.bookId &&
      chapterId == other.chapterId &&
      blockId == other.blockId &&
      utf16Offset == other.utf16Offset &&
      affinity == other.affinity;

  @override
  bool operator ==(Object other) =>
      other is Locator &&
      samePosition(other) &&
      contentVersion == other.contentVersion &&
      needsRelocation == other.needsRelocation &&
      imageResource == other.imageResource &&
      exact == other.exact &&
      prefix == other.prefix &&
      suffix == other.suffix;

  @override
  int get hashCode => Object.hash(
        bookId,
        chapterId,
        blockId,
        utf16Offset,
        affinity,
        contentVersion,
      );

  @override
  String toString() =>
      'Locator($chapterId/$blockId@$utf16Offset${affinity == LocatorAffinity.center ? '' : '·${affinity.name}'})';
}

/// 章内页码引用：只在一次排版内有效（设计文档 6.3）。
class PageRef {
  const PageRef({required this.chapterId, required this.pageIndex});

  final String chapterId;
  final int pageIndex;

  @override
  bool operator ==(Object other) =>
      other is PageRef &&
      other.chapterId == chapterId &&
      other.pageIndex == pageIndex;

  @override
  int get hashCode => Object.hash(chapterId, pageIndex);

  @override
  String toString() => 'PageRef($chapterId#$pageIndex)';
}

/// 选区（原型）：两个位置界定的文本范围，顺序不保证，比较时按阅读顺序规范化。
class SelectionRange {
  const SelectionRange({required this.start, required this.end});

  final Locator start;
  final Locator end;

  /// 两端是否在同一章（跨章选区本轮不验证）
  bool get isSingleChapter => start.chapterId == end.chapterId;
}

/// 两段选文是不是落在同一处：两端位置相同即可，前后次序无所谓。
///
/// 用于「同一选区再操作就是改那一条」（实现计划 N5）：只看位置，
/// 不看摘录文字——同一句话在书里可能出现很多次，按文字判重会误合并。
bool sameSelectionRange(SelectionRange a, SelectionRange b) =>
    (a.start.samePosition(b.start) && a.end.samePosition(b.end)) ||
    (a.start.samePosition(b.end) && a.end.samePosition(b.start));
