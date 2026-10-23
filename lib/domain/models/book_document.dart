/// 标准化正文模型：EPUB / TXT / MOBI / AZW3 都输出同一套结构。
///
/// 设计文档 6.3：`BookDocument → Chapter → ContentBlock → TextRun / Resource`。
/// 块只保留语义（标题级别、加粗、斜体、图片），不存 Widget，也不保留
/// 复杂 CSS。章节与块 ID 在同一内容版本内稳定，供阶段 3 的 Locator 使用。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'content_table.dart';
import 'source_content_index.dart';
import 'locator.dart';
import 'pdf_page_info.dart';

/// 当前正文版本号。
///
/// 章节 ID 方案、空白折叠规则或内容口径变化时必须递增，旧版本章节仍可解码，
/// 避免历史笔记位置直接失效（设计文档 6.1）。
const int kContentVersion = 2;

/// 目录及 EPUB 显示资料的生成规则标记，仅用于跳过已完成的旧书修复。
/// 它们不改变正文坐标，也不递增正文版本或应用版本。
const int kTocRevision = 1;
const int kEpubDetailsRevision = 1;

/// 块类型。
enum BlockKind {
  heading('heading'),
  paragraph('paragraph'),
  listItem('listItem'),
  image('image'),
  divider('divider'),
  footnote('footnote');

  const BlockKind(this.code);
  final String code;

  static BlockKind fromCode(String code) => values.firstWhere(
    (k) => k.code == code,
    orElse: () => BlockKind.paragraph,
  );
}

/// 一段带语义样式的文本。样式只保留加粗/斜体（CSS 白名单的产物）。
class TextRun {
  const TextRun(this.text, {this.bold = false, this.italic = false});

  final String text;
  final bool bold;
  final bool italic;

  bool get isPlain => !bold && !italic;

  Map<String, Object?> toJson() => {
    'text': text,
    if (bold) 'bold': true,
    if (italic) 'italic': true,
  };

  static TextRun fromJson(Map<String, Object?> json) => TextRun(
    json['text'] as String? ?? '',
    bold: json['bold'] == true,
    italic: json['italic'] == true,
  );
}

/// 正文块。
///
/// 图片块通过 `resourcePath` 指向已落盘资源（相对正文根目录）；
/// 段落内的行内图片会被拆成「前文本块 + 图片块 + 后文本块」，不使用占位字符。
class ContentBlock {
  const ContentBlock({
    required this.id,
    required this.kind,
    this.runs = const [],
    this.level,
    this.resourcePath,
    this.resourceWidth,
    this.resourceHeight,
    this.alt,
    this.target,
  });

  /// 章内稳定 ID，形如 `b12`
  final String id;
  final BlockKind kind;
  final List<TextRun> runs;

  /// 标题级别（1–6），仅 heading 有值
  final int? level;

  /// 图片资源相对路径（形如 `res/OEBPS/Images/p1.jpg`），仅 image 有值
  final String? resourcePath;
  final int? resourceWidth;
  final int? resourceHeight;

  /// 图片替代文字或脚注文本
  final String? alt;

  /// 内部链接或脚注目标（阶段 3 使用）
  final String? target;

  /// 本块文本长度（UTF-16 code unit），用于进度分母
  int get textLength {
    var n = 0;
    for (final r in runs) {
      n += r.text.length;
    }
    // 块之间按一个字符计，保证空块（图片/分隔线）也有位置权重
    return n + 1;
  }

  /// 是否没有任何可显示的内容（空段落、空容器）。
  ///
  /// 图片块没有文字 runs，但它是有内容的：解析时若把它当成空块丢掉，
  /// 整页都是图的漫画、插图章节就会变成空章。
  bool get isContentless => runs.isEmpty && kind != BlockKind.image;

  Map<String, Object?> toJson() => {
    'id': id,
    'kind': kind.code,
    if (runs.isNotEmpty)
      'runs': [for (final r in runs) r.isPlain ? r.text : r.toJson()],
    if (level != null) 'level': level,
    if (resourcePath != null) 'resource': resourcePath,
    if (resourceWidth != null) 'width': resourceWidth,
    if (resourceHeight != null) 'height': resourceHeight,
    if (alt != null) 'alt': alt,
    if (target != null) 'target': target,
  };

  /// 解码单块。`runs` 中纯字符串表示无样式的文本，对象则带样式。
  static ContentBlock fromJson(Map<String, Object?> json) {
    final rawRuns = json['runs'];
    final runs = <TextRun>[];
    if (rawRuns is List) {
      for (final raw in rawRuns) {
        if (raw is String) {
          runs.add(TextRun(raw));
        } else if (raw is Map) {
          runs.add(TextRun.fromJson(raw.cast<String, Object?>()));
        }
      }
    }
    return ContentBlock(
      id: json['id'] as String? ?? '',
      kind: BlockKind.fromCode(json['kind'] as String? ?? 'paragraph'),
      runs: runs,
      level: (json['level'] as num?)?.toInt(),
      resourcePath: json['resource'] as String?,
      resourceWidth: (json['width'] as num?)?.toInt(),
      resourceHeight: (json['height'] as num?)?.toInt(),
      alt: json['alt'] as String?,
      target: json['target'] as String?,
    );
  }
}

/// 单章正文，落盘为 `content/<版本>/<chapterId>.json`。
class ChapterContent {
  const ChapterContent({
    required this.chapterId,
    required this.blocks,
    this.tables = const [],
    this.epubDetailsRevision = 0,
    this.pdfPage,
  });

  final String chapterId;
  final List<ContentBlock> blocks;
  final List<ContentTable> tables;
  final int epubDetailsRevision;
  final PdfPageInfo? pdfPage;

  int get textLength {
    var n = 0;
    for (final b in blocks) {
      n += b.textLength;
    }
    return n;
  }

  Map<String, Object?> toJson() => {
    'chapterId': chapterId,
    if (pdfPage != null) 'pdfPage': pdfPage!.toJson(),
    if (epubDetailsRevision > 0) 'epubDetailsRevision': epubDetailsRevision,
    'blocks': [for (final b in blocks) b.toJson()],
    if (tables.isNotEmpty) 'tables': tables.map((t) => t.toJson()).toList(),
  };

  static ChapterContent fromJson(Map<String, Object?> json) {
    final rawBlocks = json['blocks'];
    return ChapterContent(
      chapterId: json['chapterId'] as String? ?? '',
      pdfPage: json['pdfPage'] is Map
          ? PdfPageInfo.fromJson(
              (json['pdfPage'] as Map).cast<String, dynamic>(),
            )
          : null,
      epubDetailsRevision: (json['epubDetailsRevision'] as num?)?.toInt() ?? 0,
      tables: [
        for (final table in (json['tables'] as List? ?? const []))
          ContentTable.fromJson(Map<String, dynamic>.from(table as Map)),
      ],
      blocks: [
        if (rawBlocks is List)
          for (final raw in rawBlocks)
            if (raw is Map) ContentBlock.fromJson(raw.cast<String, Object?>()),
      ],
    );
  }

  Uint8List encode() => Uint8List.fromList(utf8.encode(jsonEncode(toJson())));
}

/// 章节元数据（存 `chapters` 表，正文另存单章文件）。
class Chapter {
  const Chapter({
    required this.id,
    required this.ordinal,
    required this.title,
    required this.contentPath,
    required this.textLength,
    this.href,
  });

  final String id;

  /// 阅读顺序，从 0 开始
  final int ordinal;
  final String title;

  /// 相对书籍目录的章节文件路径，形如 `content/1/ch001-ab12.json`
  final String contentPath;
  final int textLength;

  /// EPUB 原始 href，仅供调试与内部链接定位，不作为进度依据
  final String? href;
}

/// 目录节点：卷可以是嵌套的，章节叶子指向 `chapterId`。
class TocNode {
  const TocNode({
    required this.title,
    this.chapterId,
    this.fragment,
    this.children = const [],
  });

  final String title;

  /// 叶子节点指向章节；卷节点为 null
  final String? chapterId;

  /// EPUB 目录条目的原始页内锚点，原书排版可精确定位。
  /// 旧 TXT 漏识别章题使用 `gt-txt:块ID`，补目录而不重写正文。
  final String? fragment;
  final List<TocNode> children;

  bool get isLeaf => chapterId != null;

  Map<String, Object?> toJson() => {
    'title': title,
    if (chapterId != null) 'chapterId': chapterId,
    if (fragment?.isNotEmpty == true) 'fragment': fragment,
    if (children.isNotEmpty) 'children': [for (final c in children) c.toJson()],
  };

  static TocNode fromJson(Map<String, Object?> json) {
    final rawChildren = json['children'];
    return TocNode(
      title: json['title'] as String? ?? '',
      chapterId: json['chapterId'] as String?,
      fragment: json['fragment'] as String?,
      children: [
        if (rawChildren is List)
          for (final raw in rawChildren)
            if (raw is Map) TocNode.fromJson(raw.cast<String, Object?>()),
      ],
    );
  }

  /// 目录内所有章节 ID（深度优先），用于「按 spine 顺序平铺」的降级判断。
  List<String> get chapterIds => [
    ?chapterId,
    for (final c in children) ...c.chapterIds,
  ];
}

/// 一次解析的完整产物：章节元数据 + 目录 + 封面 + 兼容性提示。
///
/// 章节正文与图片资源由解析器写入提交前的暂存目录，`contentPath`、
/// `coverPath` 都相对正文根目录（`content/<版本>/`）。
class BookDocument {
  const BookDocument({
    required this.title,
    required this.author,
    required this.chapters,
    this.contentVersion = kContentVersion,
    this.toc = const [],
    this.coverPath,
    this.coverWidth,
    this.coverHeight,
    this.warnings = const [],
    this.encoding = '',
    this.tocRevision = 0,
    this.sourceIndex,
    this.locationMatches = const {},
  });

  final String title;
  final String author;
  final int contentVersion;
  final List<Chapter> chapters;

  /// 嵌套目录（分卷 + 章节）；为空时阅读器降级为章节平铺
  final List<TocNode> toc;

  /// 封面相对路径，形如 `res/cover.jpg`
  final String? coverPath;
  final int? coverWidth;
  final int? coverHeight;

  /// 兼容性提示（原文不含格式前缀，界面按需展示）
  final List<String> warnings;

  /// TXT 实际使用的编码名，EPUB 为空
  final String encoding;
  final int tocRevision;
  final SourceContentIndex? sourceIndex;

  /// 临时解析结果，单独保存核对缓存，不加入正文清单或改变正文版本。
  final Map<String, Locator?> locationMatches;

  int get textLength {
    var n = 0;
    for (final c in chapters) {
      n += c.textLength;
    }
    return n;
  }

  /// 清单文件内容（设计文档 6.1：封面资源 href + 嵌套 toc）。
  Map<String, Object?> toManifestJson() => {
    'contentVersion': contentVersion,
    if (sourceIndex != null) 'sourceIndex': sourceIndex!.toJson(),
    if (tocRevision > 0) 'tocRevision': tocRevision,
    'title': title,
    'author': author,
    if (coverPath != null) 'cover': coverPath,
    if (coverWidth != null) 'coverWidth': coverWidth,
    if (coverHeight != null) 'coverHeight': coverHeight,
    'toc': [for (final n in toc) n.toJson()],
    'chapters': [
      for (final c in chapters)
        {
          'id': c.id,
          'ordinal': c.ordinal,
          'title': c.title,
          'path': c.contentPath,
          'textLength': c.textLength,
          if (c.href != null) 'href': c.href,
        },
    ],
    if (warnings.isNotEmpty) 'warnings': warnings,
    if (encoding.isNotEmpty) 'encoding': encoding,
  };
}
