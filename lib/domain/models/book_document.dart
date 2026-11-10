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
import 'inline_box_span.dart';
import 'block_box_reference.dart';
export 'block_box_reference.dart';
export 'inline_box_span.dart';

/// 当前正文版本号。
///
/// 章节 ID 方案、空白折叠规则或内容口径变化时必须递增，旧版本章节仍可解码，
/// 避免历史笔记位置直接失效（设计文档 6.1）。
const int kContentVersion = 2;

/// 目录及 EPUB 显示资料的生成规则标记，仅用于跳过已完成的旧书修复。
/// 它们不改变正文坐标，也不递增正文版本或应用版本。
const int kTocRevision = 4;
const int kEpubDetailsRevision = 2;

/// 块类型。
///
/// `quote`（引用）、`code`（代码）、`caption`（图注）是 2026-10 扩充的语义块。
/// 它们只改变排版方式：块里的文字与旧版完全一致，阅读位置、书签和笔记不受影响。
enum BlockKind {
  heading('heading'),
  paragraph('paragraph'),
  listItem('listItem'),
  image('image'),
  divider('divider'),
  footnote('footnote'),
  quote('quote'),
  codeBlock('code'),
  caption('caption');

  const BlockKind(this.code);
  final String code;

  static BlockKind fromCode(String code) => values.firstWhere(
    (k) => k.code == code,
    orElse: () => BlockKind.paragraph,
  );
}

/// 一段带语义样式的文本。样式只保留加粗/斜体/上下标/下划线/删除线
/// （CSS 白名单的产物）。
class TextRun {
  const TextRun(
    this.text, {
    this.bold = false,
    this.italic = false,
    this.superscript = false,
    this.subscript = false,
    this.color,
    this.sizeScale = 1,
    this.underline = false,
    this.strike = false,
    this.link,
    this.footnote = false,
    this.styleId,
  });

  final String text;
  final bool bold;
  final bool italic;

  /// 书内指定的文字颜色（ARGB）；null 表示跟随阅读主题。
  final int? color;

  /// 书内指定的相对字号倍数（1 表示跟随阅读设置）。
  final double sizeScale;

  /// `<sup>` 文字：字号更小、向上偏移（脚注编号用）。
  final bool superscript;

  /// `<sub>` 文字：字号更小、向下偏移。
  final bool subscript;

  /// 下划线（`text-decoration: underline`、`<u>`、链接默认样式）。
  final bool underline;

  /// 删除线（`text-decoration: line-through`、`<del>`、`<s>`）。
  final bool strike;

  /// 书内链接目标（`章节路径#锚点`）；null 表示不是链接。
  ///
  /// 只用于点击交互（脚注气泡、书内跳转），不参与文字拼接和长度计算。
  final String? link;

  /// 是否脚注引用（`epub:type="noteref"` 或 `role="doc-noteref"`）。
  final bool footnote;

  /// 本片段在章内样式表里的编号（批次 C 起写入）；null 表示旧缓存。
  final int? styleId;

  /// 同一段文字，但换上新的样式编号。
  /// 0 表示默认样式；按约定不写进 JSON（[isPlain] 的片段会写成纯字符串）。
  TextRun withStyleId(int? value) => TextRun(
    text,
    bold: bold,
    italic: italic,
    superscript: superscript,
    subscript: subscript,
    color: color,
    sizeScale: sizeScale,
    underline: underline,
    strike: strike,
    link: link,
    footnote: footnote,
    styleId: value == null || value == 0 ? null : value,
  );

  /// 上标或下标（两者不会同时为 true）。
  bool get isScript => superscript || subscript;

  bool get isPlain =>
      !bold &&
      !italic &&
      !isScript &&
      !underline &&
      !strike &&
      link == null &&
      !footnote &&
      color == null &&
      sizeScale == 1;

  /// 只写正文与交互标记（`stylesOnly` 缓存形态）：样式由章节样式表提供。
  Object toStylesOnlyJson() => link == null && !footnote && styleId == null
      ? text
      : {
          'text': text,
          if (link != null) 'lk': link,
          if (footnote) 'fn': true,
          if (styleId != null) 'sid': styleId,
        };

  Map<String, Object?> toJson() => {
    'text': text,
    if (bold) 'bold': true,
    if (italic) 'italic': true,
    if (superscript) 'sup': true,
    if (subscript) 'sub': true,
    if (color != null) 'c': color,
    if (sizeScale != 1) 'fs': sizeScale,
    if (underline) 'u': true,
    if (strike) 'st': true,
    if (link != null) 'lk': link,
    if (footnote) 'fn': true,
    if (styleId != null) 'sid': styleId,
  };

  static TextRun fromJson(Map<String, Object?> json) => TextRun(
    json['text'] as String? ?? '',
    bold: json['bold'] == true,
    italic: json['italic'] == true,
    superscript: json['sup'] == true,
    subscript: json['sub'] == true,
    color: (json['c'] as num?)?.toInt(),
    sizeScale: (json['fs'] as num?)?.toDouble() ?? 1,
    underline: json['u'] == true,
    strike: json['st'] == true,
    link: json['lk'] as String?,
    footnote: json['fn'] == true,
    styleId: (json['sid'] as num?)?.toInt(),
  );
}

/// 段落中间的一张行内图片（生僻字做成图片时使用）。
///
/// 图片本身不占正文文字：`offset` 是它在本块文字里的位置（UTF-16），
/// 只参与显示（断行时按实际尺寸占位、绘制时画在这里）。
/// 同一位置有多张图片时按列表顺序从左到右排列。
class InlineImage {
  const InlineImage({
    required this.offset,
    required this.resourcePath,
    this.width,
    this.height,
    this.imageWidth,
    this.imageMaxWidth,
    this.alt,
    this.styleId,
  });

  /// 在本块文字里的字符位置（UTF-16 code unit）。
  final int offset;

  /// 图片资源相对路径（形如 `res/OEBPS/Images/p1.jpg`）。
  final String resourcePath;

  /// 图片文件的原始像素尺寸；取不到时为 0。
  final int? width;
  final int? height;

  /// 书里写的 `width`／`max-width`，格式与图片块相同。
  final List<int>? imageWidth;
  final List<int>? imageMaxWidth;

  final String? alt;
  final int? styleId;

  Map<String, Object?> toJson() => {
    'o': offset,
    if (styleId != null) 'sid': styleId,
    'r': resourcePath,
    'w': width ?? 0,
    'h': height ?? 0,
    if (imageWidth != null) 'iw': imageWidth,
    if (imageMaxWidth != null) 'imw': imageMaxWidth,
    if (alt != null) 'a': alt,
  };

  static InlineImage fromJson(Map<String, Object?> json) => InlineImage(
    offset: (json['o'] as num?)?.toInt() ?? 0,
    resourcePath: json['r'] as String? ?? '',
    width: (json['w'] as num?)?.toInt() ?? 0,
    height: (json['h'] as num?)?.toInt() ?? 0,
    imageWidth: json['iw'] == null
        ? null
        : [for (final value in json['iw'] as List) (value as num).toInt()],
    imageMaxWidth: json['imw'] == null
        ? null
        : [for (final value in json['imw'] as List) (value as num).toInt()],
    alt: json['a'] as String?,
    styleId: (json['sid'] as num?)?.toInt(),
  );
}

/// 正文块。
///
/// 图片块通过 `resourcePath` 指向已落盘资源（相对正文根目录）；
/// 段落中间的图片不再拆成独立块，而是记在 [inlineImages] 里，
/// 作为一个字参与行内排版，不使用占位字符。
///
/// 2026-10 起块还携带「怎么显示」的信息（对齐、缩进、列表层级、硬换行位置、
/// 代码行缩进）。这些字段都不进入正文文字：块内 runs 与旧版逐字一致，
/// 因此 Locator、书签和笔记完全不受影响。
class ContentBlock {
  ContentBlock({
    required this.id,
    required this.kind,
    this.runs = const [],
    this.level,
    this.resourcePath,
    this.resourceWidth,
    this.resourceHeight,
    this.alt,
    this.target,
    this.nest = 0,
    this.ordered = false,
    this.ordinal,
    this.breaks = const [],
    this.indents = const [],
    this.isQuoteContainer = false,
    this.boxId,
    this.parentBox,
    this.line,
    this.inlineImages = const [],
    this.inlineBoxes = const [],
    this.weight,
    this.styleId,
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

  /// 列表项／引用的嵌套层级，0 为顶层。
  final int nest;

  /// 有序列表项（父级是 `<ol>`）。
  final bool ordered;

  /// 有序列表项在列表里的序号，从 1 开始；无序列表为 null。
  final int? ordinal;

  /// 显示层的硬换行位置：块文本里这些下标的空格要画成换行。
  ///
  /// 换行是 1:1 替换（空格→换行符），不增删文字，偏移与旧版完全相同；
  /// 来源是 `<br>` 与代码块的源码换行。
  final List<int> breaks;

  /// 每个换行之后那一行开头的缩进空格数，长度与 [breaks] 相同；仅代码块使用。
  final List<int> indents;

  /// 这一块是不是 `<blockquote>` 元素本身的文字。
  ///
  /// 原书 WebView 只给 `p`／正文 `div` 补阅读器首行缩进，`blockquote` 自己
  /// 不补（引用里的段落才补）。简化排版靠这个标记区分：引用容器里的诗行
  /// 不该多出两字缩进，引用里的 `p` 仍然要缩进。
  final bool isQuoteContainer;

  /// 同一个盒子容器里的连续块共用这个编号：背景与边框连成一整块。
  ///
  /// 盒子本身的背景/边框/内边距不在块上（它们属于作者样式，存在样式表里）；
  /// 块只留这个结构编号，用来把连续块的盒子连成一整块。
  final int? boxId;

  /// 代码块自身有框时，额外保留包住它的引用容器。
  final BlockBoxReference? parentBox;

  /// 分隔线（`<hr>`）自己的线型 `[宽度(0.01em), 线型, 颜色]`；null 用默认短线。
  final List<int>? line;

  /// 本段正文中间的行内图片；为空表示没有。
  ///
  /// 只有显示意义：不改变 runs、正文文字或阅读位置。
  final List<InlineImage> inlineImages;

  /// 行内背景、边框及内边距；只影响显示，不改变正文与阅读位置。
  final List<InlineBoxSpan> inlineBoxes;

  /// 位置权重覆盖值。
  ///
  /// 行内图片把原来「前文本块 + 图片块 + 后文本块」合成一块。为了不让章节
  /// 文字总长、进度分母和导入时保存的长度发生变化，转换器按合并前的分块口径
  /// 算好原来的权重存在这里；不需要覆盖时为 null，仍按「文字 + 1」计算。
  final int? weight;

  /// 本块在章内样式表里的编号（批次 C 起写入，方案 2 收尾后是唯一的样式来源）。
  ///
  /// null 表示「默认样式」（样式表 0 号记录）；样式表本身在 [ChapterContent.stylesJson]。
  /// 对齐、缩进、盒子、阴影、列表标记、字距词距、外边距、图片显式宽高都在表里，
  /// 块不再携带这些字段。
  final int? styleId;

  /// 同一块，但换上新的样式编号（建表后把样式表接到正文模型上）。
  ContentBlock withStyleIds(int? blockStyleId, List<int?> runStyleIds) =>
      ContentBlock(
        id: id,
        kind: kind,
        runs: [
          for (var i = 0; i < runs.length; i++)
            runs[i].withStyleId(i < runStyleIds.length ? runStyleIds[i] : null),
        ],
        level: level,
        resourcePath: resourcePath,
        resourceWidth: resourceWidth,
        resourceHeight: resourceHeight,
        alt: alt,
        target: target,
        nest: nest,
        ordered: ordered,
        ordinal: ordinal,
        breaks: breaks,
        indents: indents,
        isQuoteContainer: isQuoteContainer,
        boxId: boxId,
        parentBox: parentBox,
        line: line,
        inlineImages: inlineImages,
        inlineBoxes: inlineBoxes,
        weight: weight,
        styleId: blockStyleId == null || blockStyleId == 0
            ? null
            : blockStyleId,
      );

  /// 本块 runs 的文字长度（UTF-16 code unit）
  int get runLength {
    var n = 0;
    for (final r in runs) {
      n += r.text.length;
    }
    return n;
  }

  /// 本块文本长度（UTF-16 code unit），用于进度分母
  int get textLength => weight ?? (runLength + 1);

  /// 是否没有任何可显示的内容（空段落、空容器）。
  ///
  /// 图片块没有文字 runs，但它是有内容的：解析时若把它当成空块丢掉，
  /// 整页都是图的漫画、插图章节就会变成空章。
  bool get isContentless =>
      runs.isEmpty && kind != BlockKind.image && inlineImages.isEmpty;

  /// 序列化单块：只写正文与结构。
  ///
  /// 显示样式（对齐、盒子、阴影、列表标记、字距词距、外边距、图片宽高、片段的
  /// 字体/颜色）不在这里：它们只存一份在章节样式表的 `styles` 里，块与片段用
  /// `sid` 指过去（[ChapterContent.stylesJson]）。
  Map<String, Object?> toJson() => {
    'id': id,
    'kind': kind.code,
    if (runs.isNotEmpty) 'runs': [for (final r in runs) r.toStylesOnlyJson()],
    if (level != null) 'level': level,
    if (resourcePath != null) 'resource': resourcePath,
    if (resourceWidth != null) 'width': resourceWidth,
    if (resourceHeight != null) 'height': resourceHeight,
    if (alt != null) 'alt': alt,
    if (target != null) 'target': target,
    if (nest > 0) 'nest': nest,
    if (ordered) 'ordered': true,
    if (ordinal != null) 'ordinal': ordinal,
    if (breaks.isNotEmpty) 'breaks': breaks,
    if (indents.isNotEmpty) 'indents': indents,
    if (isQuoteContainer) 'qb': true,
    if (boxId != null) 'boxId': boxId,
    if (parentBox != null) 'parentBox': parentBox!.toJson(),
    if (line != null) 'ln': line,
    if (inlineImages.isNotEmpty)
      'iim': [for (final image in inlineImages) image.toJson()],
    if (inlineBoxes.isNotEmpty)
      'ib': [for (final box in inlineBoxes) box.toJson()],
    if (weight != null) 'w': weight,
    // 样式表编号：null 就是默认样式（0 号记录），不写进 JSON。
    if (styleId != null) 'sid': styleId,
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
      nest: (json['nest'] as num?)?.toInt() ?? 0,
      ordered: json['ordered'] == true,
      ordinal: (json['ordinal'] as num?)?.toInt(),
      breaks: [
        for (final value in (json['breaks'] as List? ?? const []))
          (value as num).toInt(),
      ],
      indents: [
        for (final value in (json['indents'] as List? ?? const []))
          (value as num).toInt(),
      ],
      isQuoteContainer: json['qb'] == true,
      boxId: (json['boxId'] as num?)?.toInt(),
      parentBox: json['parentBox'] is Map
          ? BlockBoxReference.fromJson(
              (json['parentBox'] as Map).cast<String, Object?>(),
            )
          : null,
      line: json['ln'] == null
          ? null
          : [for (final value in json['ln'] as List) (value as num).toInt()],
      inlineImages: [
        for (final raw in (json['iim'] as List? ?? const []))
          if (raw is Map) InlineImage.fromJson(raw.cast<String, Object?>()),
      ],
      inlineBoxes: [
        for (final raw in (json['ib'] as List? ?? const []))
          InlineBoxSpan.fromJson((raw as Map).cast<String, Object?>()),
      ],
      weight: (json['w'] as num?)?.toInt(),
      styleId: (json['sid'] as num?)?.toInt(),
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
    this.stylesJson,
    this.displaySourceJson,
  });

  final String chapterId;
  final List<ContentBlock> blocks;
  final List<ContentTable> tables;
  final int epubDetailsRevision;
  final PdfPageInfo? pdfPage;

  /// 本章样式表的原始 JSON（批次 C 起随正文一起缓存）；null 表示旧缓存。
  ///
  /// 这里刻意存原始 JSON 而不是解析后的对象：ChapterContent 属于领域模型，
  /// 不反向依赖排版引擎；解码成 StyleTable 由排版层按需做（很快，且有缓存）。
  /// 块和片段的 [ContentBlock.styleId]／[TextRun.styleId] 指向这张表。
  final Map<String, Object?>? stylesJson;

  /// 显示来源索引（纯数据）：元素父子、顺序、块范围和表格引用。
  /// 旧缓存没有它时为空，排版退回扁平块 + 现有盒子关系。
  final Map<String, Object?>? displaySourceJson;

  int get textLength {
    var n = 0;
    for (final b in blocks) {
      n += b.textLength;
    }
    return n;
  }

  /// 写入正文缓存：正文与结构一份，样式表一份（`styles`），块与片段用 `sid` 指过去。
  Map<String, Object?> toJson() => {
    'chapterId': chapterId,
    if (pdfPage != null) 'pdfPage': pdfPage!.toJson(),
    if (epubDetailsRevision > 0) 'epubDetailsRevision': epubDetailsRevision,
    'blocks': [for (final b in blocks) b.toJson()],
    if (tables.isNotEmpty) 'tables': tables.map((t) => t.toJson()).toList(),
    if (stylesJson != null) 'styles': stylesJson,
    if (displaySourceJson != null) 'displaySource': displaySourceJson,
  };

  static ChapterContent fromJson(Map<String, Object?> json) {
    final rawBlocks = json['blocks'];
    final rawStyles = json['styles'];
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
      stylesJson: rawStyles is Map ? rawStyles.cast<String, Object?>() : null,
      displaySourceJson: json['displaySource'] is Map
          ? (json['displaySource'] as Map).cast<String, Object?>()
          : null,
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
    this.usesIndentedTxtHeadings = false,
    this.usesCombinedTxtHeadings = false,
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

  /// 本次切章采用了缩进标题，旧版生成的章节与正文位置需要重新核对。
  final bool usesIndentedTxtHeadings;

  /// 篇、卷与章名合写的标题参与了本次切章。
  final bool usesCombinedTxtHeadings;
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
