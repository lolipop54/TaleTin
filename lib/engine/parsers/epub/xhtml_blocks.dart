/// XHTML 正文 → 统一内容块。
///
/// 只保留语义：标题级别、段落、列表项、图片、分隔线、脚注目标，以及
/// 加粗/斜体两种行内样式（设计文档 6.2「CSS 白名单」）。`<style>` 块、
/// class/id 选择器、颜色字体对齐等一律忽略，并记录 `stylesheetIgnored`。
library;

import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;

import '../../../domain/models/book_document.dart';
import '../../../domain/models/content_table.dart';
import 'dom_text_map.dart';
import '../../normalization/display_hyphens.dart';
import 'epub_archive.dart';
import 'epub_dom.dart';

/// 图片解析结果：已落盘资源路径 + 尺寸。
class ResolvedImage {
  const ResolvedImage({
    required this.resourcePath,
    required this.width,
    required this.height,
  });

  final String resourcePath;
  final int width;
  final int height;
}

/// 解析一行内引用的图片；返回 null 表示该图片不可用（跳过）。
typedef ImageResolver = ResolvedImage? Function(String entryPath);

class XhtmlBlocks {
  const XhtmlBlocks({
    required this.blocks,
    required this.headingTitle,
    required this.warnings,
    this.textMap,
    this.tables = const [],
  });

  final List<ContentBlock> blocks;
  final List<ContentTable> tables;

  /// 第一个标题（或首段摘录），作为章节标题兜底
  final String? headingTitle;
  final Set<String> warnings;

  /// DOM 文本节点 ↔ 块内偏移的对照表（听书锚点定位用，见 `dom_text_map.dart`）。
  ///
  /// 与 [blocks] 来自同一次遍历，因此两者一定对应；没有正文时为 null。
  final DomTextMap? textMap;
}

class XhtmlBlockBuilder {
  XhtmlBlockBuilder({required this.basePath, required this.resolveImage});

  /// 当前 XHTML 在归档内的路径，用于解析相对引用
  final String basePath;
  final ImageResolver resolveImage;

  /// 兼容性提示：直接面向读者展示，不用内部代码名
  static const String warningStylesheet = '部分排版样式已忽略';
  static const String warningTable = '表格已简化，仅保留文字与图片';

  final List<ContentBlock> _blocks = [];
  final List<ContentTable> _tables = [];
  final List<TextRun> _runs = [];
  final Set<String> _warnings = {};

  /// 当前段落收集到的来源片段，供对照表使用（见 [XhtmlBlocks.textMap]）
  final List<SourcePiece> _pieces = [];
  final DomTextMapBuilder _textMap = DomTextMapBuilder();

  Document? _document;

  /// 最近一次 [convert] 解析出来的 DOM。
  ///
  /// 锚点定位要按 id 找元素、再拿文本节点去查对照表，
  /// 必须用**同一份文档**里的节点对象（各次解析出来的节点身份不同、查不到）。
  Document? get document => _document;

  int _seq = 0;
  int? _blockLevel;
  BlockKind _blockKind = BlockKind.paragraph;
  String? _blockTarget;
  String? _headingTitle;

  /// 参与块产出的标签 → 块类型
  static const Map<String, BlockKind> _blockTags = {
    'p': BlockKind.paragraph,
    'li': BlockKind.listItem,
    'dd': BlockKind.paragraph,
    'dt': BlockKind.paragraph,
    'figcaption': BlockKind.paragraph,
    'pre': BlockKind.paragraph,
    'blockquote': BlockKind.paragraph,
    'td': BlockKind.paragraph,
    'th': BlockKind.paragraph,
  };

  /// 只做块边界的容器：本身不产出块，但会断开上下段落。
  static const Set<String> _boundaryTags = {
    'div',
    'section',
    'article',
    'aside',
    'header',
    'footer',
    'main',
    'nav',
    'figure',
    'ul',
    'ol',
    'dl',
    'table',
    'tr',
    'tbody',
    'thead',
    'tfoot',
    'body',
    'html',
    'center',
    'form',
    'fieldset',
    'details',
    'summary',
    'address',
    'caption',
    'colgroup',
    'col',
  };

  /// 完全忽略的标签（脚本、媒体、嵌入内容）
  static const Set<String> _ignoredTags = {
    'script',
    'noscript',
    'iframe',
    'object',
    'embed',
    'audio',
    'video',
    'canvas',
    'map',
    'area',
    'source',
    'track',
    'template',
    'meta',
    'base',
    'param',
    'input',
    'button',
    'select',
    'option',
    'textarea',
  };

  XhtmlBlocks convert(String source) {
    final document = html_parser.parse(source);
    _document = document;
    final body = document.body;
    if (body == null) {
      return XhtmlBlocks(
        blocks: const [],
        headingTitle: null,
        warnings: _warnings,
        textMap: DomTextMap.empty,
      );
    }
    _walkAll(body.nodes, const _InlineStyle());
    _flush();
    _dropLeadingEmpty();
    return XhtmlBlocks(
      blocks: List.unmodifiable(_blocks),
      headingTitle: _headingTitle,
      warnings: _warnings,
      textMap: _textMap.build(),
      tables: List.unmodifiable(_tables),
    );
  }

  void _walkAll(List<Node> nodes, _InlineStyle style) {
    for (final node in nodes) {
      _walk(node, style);
    }
  }

  void _walk(Node node, _InlineStyle style) {
    if (node is Text) {
      _addText(node.text, style, node: node);
      return;
    }
    if (node is! Element) return;

    final tag = node.localName?.toLowerCase() ?? '';
    if (tag == 'style' || tag == 'link') {
      _warnings.add(warningStylesheet);
      return;
    }
    if (_ignoredTags.contains(tag)) return;
    if (tag == 'table') {
      _emitTable(node, style);
      return;
    }

    final elementStyle = _resolveStyle(node, style);

    if (tag == 'br') {
      _addText('\n', elementStyle);
      return;
    }
    if (tag == 'img' || tag == 'image') {
      _emitImage(node);
      return;
    }
    if (tag == 'hr') {
      _flush();
      _blocks.add(ContentBlock(id: _nextId(), kind: BlockKind.divider));
      return;
    }
    if (tag == 'svg') {
      // 固定版式书籍常用 SVG 画封面，按图片处理
      _emitSvgImage(node);
      return;
    }

    final level = _headingLevel(tag);
    if (level != null) {
      _begin(BlockKind.heading, level: level);
      _walkAll(node.nodes, elementStyle);
      _end();
      return;
    }

    final blockKind = _blockTags[tag];
    if (blockKind != null) {
      _begin(blockKind);
      _walkAll(node.nodes, elementStyle);
      _end();
      return;
    }

    if (_boundaryTags.contains(tag)) {
      _flush();
      _walkAll(node.nodes, elementStyle);
      return;
    }

    // 其余标签按行内内容处理：文字照常进入当前段落，不丢内容
    if (tag == 'a') _trackFootnote(node);
    _walkAll(node.nodes, elementStyle);
  }

  int? _headingLevel(String tag) {
    if (tag.length == 2 && tag[0] == 'h') {
      final level = int.tryParse(tag[1]);
      if (level != null && level >= 1 && level <= 6) return level;
    }
    return null;
  }

  /// 保持旧版逐单元格的块产出顺序，同时记录跨度及空单元格。
  void _emitTable(Element table, _InlineStyle style) {
    _flush();
    final nestedStart = _tables.length;
    final cells = <ContentTableCell>[];
    final occupied = <(int, int)>{};
    var row = -1, columns = 0, rows = 0;
    void visit(Node node) {
      if (node is! Element) { _walk(node, style); return; }
      final tag = node.localName;
      if (tag == 'tr') {
        row++;
        for (final child in node.nodes) { visit(child); }
        _flush();
      } else if (tag == 'td' || tag == 'th') {
        if (row < 0) row = 0;
        var column = 0;
        while (occupied.contains((row, column))) { column++; }
        final rs = (int.tryParse(node.attributes['rowspan'] ?? '') ?? 1).clamp(1, 1000);
        final cs = (int.tryParse(node.attributes['colspan'] ?? '') ?? 1).clamp(1, 1000);
        _flush();
        final first = _blocks.length;
        _walk(node, style);
        _flush();
        cells.add(ContentTableCell(blocks: _blocks.skip(first).map((b) => b.id).toList(),
          row: row, column: column, rowSpan: rs, columnSpan: cs, header: tag == 'th'));
        for (var r = row; r < row + rs; r++) {
          for (var c = column; c < column + cs; c++) { occupied.add((r, c)); }
        }
        if (column + cs > columns) columns = column + cs;
        if (row + rs > rows) rows = row + rs;
      } else if (tag == 'thead' || tag == 'tbody' || tag == 'tfoot') {
        for (final child in node.nodes) { visit(child); }
      } else { _walk(node, style); }
    }
    for (final node in table.nodes) { visit(node); }
    _flush();
    if (cells.isNotEmpty && cells.any((c) => c.blocks.isNotEmpty)) {
      // 外层单元格拥有内层文字，避免同一正文被重复排版。
      _tables.removeRange(nestedStart, _tables.length);
      _tables.add(ContentTable(cells, columns, rows));
    }
  }

  void _emitImage(Element element) {
    final src =
        domAttribute(element, 'src') ??
        domAttribute(element, 'xlink:href') ??
        domAttribute(element, 'href');
    if (src == null) return;
    final entryPath = resolveEntryPath(basePath, src);
    if (entryPath == null) return;
    final resolved = resolveImage(entryPath);
    if (resolved == null) return;
    // 段落内的图片：先把已收集的文字收成前文本块，图片之后继续收集后文本块
    _flush();
    _blocks.add(
      ContentBlock(
        id: _nextId(),
        kind: BlockKind.image,
        resourcePath: resolved.resourcePath,
        resourceWidth: resolved.width,
        resourceHeight: resolved.height,
        alt: domAttribute(element, 'alt'),
      ),
    );
  }

  void _emitSvgImage(Element svg) {
    // SVG 封面常写成 <svg><image xlink:href="..."/></svg>。
    // 注意 xlink:href 在 html 包里是带命名空间的属性，必须用 domAttribute 取
    // （见 epub_dom.dart：按下标用字符串查会静默查不到，整章就会变成空页）。
    final nested = svg.querySelector('image');
    if (nested == null) return;
    _emitImage(nested);
  }

  /// 脚注引用：记录目标，供阶段 3 跳回原文。
  void _trackFootnote(Element anchor) {
    final type = domAttribute(anchor, 'epub:type') ?? '';
    final role = domAttribute(anchor, 'role') ?? '';
    if (!type.contains('noteref') && !role.contains('doc-noteref')) return;
    final href = domAttribute(anchor, 'href');
    if (href == null) return;
    final entryPath = resolveEntryPath(basePath, href);
    if (entryPath != null) _blockTarget ??= entryPath;
  }

  void _begin(BlockKind kind, {int? level}) {
    _flush();
    _blockKind = kind;
    _blockLevel = level;
  }

  void _end() => _flush();

  /// 结束当前段落：去掉首尾空白，合并同格式片段。
  void _flush() {
    final runs = _trimRuns(_runs);
    final pieces = List<SourcePiece>.of(_pieces);
    _runs.clear();
    _pieces.clear();
    final kind = _blockKind;
    final level = _blockLevel;
    final target = _blockTarget;
    _blockKind = BlockKind.paragraph;
    _blockLevel = null;
    _blockTarget = null;
    if (runs.isEmpty) return;
    final text = runs.map((r) => r.text).join();
    if (kind == BlockKind.heading && _headingTitle == null) {
      _headingTitle = text.length > 60 ? text.substring(0, 60) : text;
    } else if (_headingTitle == null && kind == BlockKind.paragraph) {
      _headingTitle = text.length > 60 ? text.substring(0, 60) : text;
    }
    final id = _nextId();
    _blocks.add(
      ContentBlock(
        id: id,
        kind: kind,
        runs: runs,
        level: level,
        target: target,
      ),
    );
    // 同一趟遍历里记下「这段文字来自 DOM 的哪些节点」（听书锚点定位用）
    _textMap.addBlock(id, text, pieces);
  }

  void _addText(String raw, _InlineStyle style, {Text? node}) {
    final displayBreaks = node == null
        ? const <int>[]
        : insertedHyphensOf(node);
    raw = removeInsertedHyphens(raw, displayBreaks);
    if (raw.isEmpty) return;
    // 连续空白折叠为单个空格；换行只在 <br> 处出现
    final normalized = collapseWhitespace(raw);
    if (normalized.isEmpty) return;
    if (normalized == ' ' && _runs.isEmpty) return;
    final last = _runs.isEmpty ? null : _runs.last;
    final merges =
        last != null && last.bold == style.bold && last.italic == style.italic;
    // 正文按同样式 run 合并、分别裁掉首尾空白；对照表必须保留这条边界。
    _pieces.add(
      SourcePiece(
        node: node,
        raw: raw,
        displayBreaks: displayBreaks,
        runIndex: merges ? _runs.length - 1 : _runs.length,
      ),
    );
    if (merges) {
      _runs[_runs.length - 1] = TextRun(
        _mergeSpaces(last.text, normalized),
        bold: last.bold,
        italic: last.italic,
      );
      return;
    }
    _runs.add(TextRun(normalized, bold: style.bold, italic: style.italic));
  }

  /// 相邻同格式片段拼接时，避免产生连续两个空格。
  static String _mergeSpaces(String left, String right) {
    if (left.endsWith(' ') && right.startsWith(' ')) {
      return '$left${right.substring(1)}';
    }
    return '$left$right';
  }

  /// 去掉块首尾空白，并丢弃空片段。
  static List<TextRun> _trimRuns(List<TextRun> runs) {
    final result = <TextRun>[];
    for (final run in runs) {
      final text = run.text
          .replaceAll(RegExp(r'^\n+|^ +'), '')
          .replaceAll(RegExp(r'\n+$| +$'), '');
      if (text.isEmpty) continue;
      result.add(TextRun(text, bold: run.bold, italic: run.italic));
    }
    if (result.isEmpty) return result;
    // 块内空行折叠成一次换行
    final cleaned = <TextRun>[];
    var previousNewline = false;
    for (final run in result) {
      final text = run.text.replaceAll(RegExp(r'\n{2,}'), '\n');
      final isNewline = text == '\n';
      if (isNewline && previousNewline) continue;
      previousNewline = isNewline || text.endsWith('\n');
      cleaned.add(TextRun(text, bold: run.bold, italic: run.italic));
    }
    return cleaned;
  }

  /// 去掉开头的空块：`<body>`、`<div>` 这类边界可能先产出一个没有内容的段落。
  ///
  /// 只删真正没有内容的块。图片块没有文字 runs，但它是页面的全部内容
  /// （漫画页、插图章首），删掉会让整章变空。
  void _dropLeadingEmpty() {
    while (_blocks.isNotEmpty && _blocks.first.isContentless) {
      _blocks.removeAt(0);
    }
  }

  String _nextId() => 'b${++_seq}';

  /// 行内样式的白名单解析：行内 style > 结构标签 > 继承（设计文档 6.2）。
  _InlineStyle _resolveStyle(Element element, _InlineStyle parent) {
    var bold = parent.bold;
    var italic = parent.italic;
    var suppressBold = parent.suppressBold;
    var suppressItalic = parent.suppressItalic;

    final style = element.attributes['style'];
    if (style != null && style.isNotEmpty) {
      final declarations = _parseStyleAttribute(style);
      final weight = declarations['font-weight'];
      if (weight != null) {
        if (_isBoldWeight(weight)) {
          bold = true;
          suppressBold = false;
        } else {
          bold = false;
          suppressBold = true;
        }
      }
      final fontStyle = declarations['font-style'];
      if (fontStyle != null) {
        if (_isItalicStyle(fontStyle)) {
          italic = true;
          suppressItalic = false;
        } else {
          italic = false;
          suppressItalic = true;
        }
      }
    }

    final tag = element.localName?.toLowerCase() ?? '';
    if (!suppressBold && (tag == 'strong' || tag == 'b')) bold = true;
    if (!suppressItalic && (tag == 'em' || tag == 'i')) italic = true;

    return _InlineStyle(
      bold: bold,
      italic: italic,
      suppressBold: suppressBold,
      suppressItalic: suppressItalic,
    );
  }

  /// 解析行内 style：只认白名单属性，其余属性记录提示后忽略。
  Map<String, String> _parseStyleAttribute(String raw) {
    final result = <String, String>{};
    for (final part in raw.split(';')) {
      final colon = part.indexOf(':');
      if (colon <= 0) continue;
      final key = part.substring(0, colon).trim().toLowerCase();
      final value = part.substring(colon + 1).trim().toLowerCase();
      if (value.isEmpty) continue;
      if (key == 'font-weight' || key == 'font-style') {
        result[key] = value;
      } else {
        _warnings.add(warningStylesheet);
      }
    }
    return result;
  }

  static bool _isBoldWeight(String value) {
    if (value == 'bold' || value == 'bolder') return true;
    final numeric = int.tryParse(value);
    return numeric != null && numeric >= 600;
  }

  static bool _isItalicStyle(String value) =>
      value == 'italic' || value == 'oblique';
}

/// 继承中的行内样式状态。
class _InlineStyle {
  const _InlineStyle({
    this.bold = false,
    this.italic = false,
    this.suppressBold = false,
    this.suppressItalic = false,
  });

  final bool bold;
  final bool italic;

  /// 结构标签的加粗/斜体是否被显式 `normal` 关闭
  final bool suppressBold;
  final bool suppressItalic;
}
