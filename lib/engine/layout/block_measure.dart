///
/// 块测量：把 [ContentBlock] 交给 TextPainter 量成行信息（实现计划 4 / 5.6）。
///
/// 这里是引擎里少数几个直接使用 TextPainter 的地方之一；另一半是绘制时的
/// `paintPage`。两边必须用 [LayoutOptions] 给出的同一份样式与同一个宽度，
/// 否则会出现「页尾整行空白」这类 1px 级偏差（设计文档 6.4）。
library;

import 'dart:math' as math;

import 'package:flutter/painting.dart';
import 'package:characters/characters.dart';

import '../../core/diagnostics/app_errors.dart';
import 'math_typesetting.dart';
import 'math_formula.dart';
import 'book_language.dart';
import 'fixed_indent.dart';
import 'measured_paragraphs.dart';
import 'float_line_space.dart';

import '../../domain/models/book_document.dart';
import '../../domain/models/display_source_index.dart';
import '../../domain/models/reading_settings.dart';
import '../styles/style_table.dart';
import '../styles/computed_style.dart';
import '../styles/style_box_value.dart';
import '../styles/style_value.dart';
import 'resolve_block_box.dart';
import 'table_layout.dart' show measureEmptyGrid;
import 'block_style_resolver.dart';
import 'display_tree.dart';
import 'display_role.dart';
import 'display_semantics.dart';
import 'display_link_semantics.dart';
import 'display_spaces.dart';
import 'display_position.dart';
import 'display_box_layout.dart';
import 'book_image_fit.dart';
import 'gallery_layout.dart';
import 'line_text_geometry.dart';
import 'box_size_resolver.dart';
import 'layout_options.dart';
import 'measured_block.dart';
import 'english_hyphenation.dart';
import 'prose_line_breaks.dart';
import 'edge_aligned_text_painter.dart';
import 'block_measurement_cache.dart';
import 'run_style_resolver.dart';
import 'ruby_source.dart';
import 'vertical_margins.dart';

part 'inline_text_measure.dart';
part 'inline_text_wrapping.dart';
part 'inline_line_spacing.dart';

part 'inline_composed_rows.dart';
part 'inline_text_box.dart';
part 'block_box_measure.dart';
part 'block_inset_measure.dart';
part 'divider_measure.dart';
part 'code_block_measure.dart';
part 'readable_text_gap.dart';
part 'display_empty_measure.dart';
part 'text_block_measure.dart';
part 'display_text_measure.dart';
part 'math_block_measure.dart';
part 'hyphen_line_fit.dart';
part 'inline_image_measure.dart';
part 'image_wrapper_measure.dart';
part 'block_image_measure.dart';
part 'float_text_measure.dart';

class BlockMeasurer {
  BlockMeasurer(
    this.options, {
    this.styleTable,
    this.displayTree,
    this.formulaTree,
    this.flatNest = false,
    this.authorTableCell = false,
    this.tableBody = false,
    this.normalFlow = true,
    this.paginated = true,
    this.outOfFlow = const {},
    this.floatLineEdges,
    this.floatContentWidth,
    this.paragraphs,
    BlockMeasurementCache? cache,
  }) : _cache = cache ?? BlockMeasurementCache();
  final BlockMeasurementCache _cache;
  final MeasuredParagraphs? paragraphs;
  Future<void>? _mathPreparation;
  Map<int, Set<int>>? _displayFormulaStarts;
  // 一个测量器的排版参数固定；长章反复使用相同样式，不必逐段重新构造。
  final _styles = <Object, TextStyle>{};
  final _listWidths = <int, double>{};
  final _markerWidths = <(String, TextStyle), double>{};
  int cacheHits = 0, measuredBlocks = 0;

  final LayoutOptions options;
  late final _readableTextGap = _ReadableTextGap(options);

  /// 这一章的样式表；块按 `styleId` 从它取样式，没有表时按默认样式排版。
  final StyleTable? styleTable;

  /// 当前章的显示树；有来源索引时提供祖先容器链，没有则退回扁平块。
  final DisplayTree? displayTree;

  /// 表格的几何由列宽决定，只借用同一来源树中的公式资料。
  final DisplayTree? formulaTree;

  /// 表格单元格用：单元格位置已经由表格列宽决定，不能再叠加引用／列表的
  /// 嵌套缩进，否则每格文字可用宽度会少掉两字，宽词被过早拆行。
  final bool flatNest;

  /// 精排表格用书内字号测图文和以 em 为单位的格内尺寸。
  final bool authorTableCell;

  /// 普通表格单元格正文沿用阅读器两端对齐，表头仍遵守作者对齐。
  final bool tableBody;
  final bool normalFlow;
  final bool paginated;
  final Set<int> outOfFlow;
  final ({double left, double right})? floatLineEdges;
  final ({int elementId, double width})? floatContentWidth;

  /// 章题装饰块使用的块 ID：它不是正文块，正文拼接校验时跳过。
  static const String titleBlockId = '__chapter_title__';

  ///
  /// 测量一个正文块。
  ///
  /// [withIndent] 仅对正文段落的**段首**为 true；跨页片段不带缩进，
  /// 这样测量与渲染才一致（实现计划 5.2）。
  /// [asChapterTitle] 把章首那个标题按章题样式测量（大字号 + 短分隔线）。
  MeasuredBlock measure(
    ContentBlock block, {
    bool withIndent = false,
    bool asChapterTitle = false,
    int sourceOffset = 0,
  }) {
    final s = options.settings;
    // Use exact dimensions and the actual TextScaler, rather than rounded samples.
    final key = (
      block,
      styleTable,
      options.contentSize,
      options.paperInset,
      options.paperBottomInset,
      options.textScaler,
      s.fontFamily,
      s.useBookFontsInSimplified,
      options.publicationFonts.identity,
      s.fontSize,
      s.fontWeight,
      s.lineHeight,
      s.paragraphGapEm,
      s.indent,
      withIndent,
      asChapterTitle,
      flatNest,
      authorTableCell,
      tableBody,
      normalFlow,
      paginated,
      floatLineEdges,
      floatContentWidth,
      EnglishHyphenation.isPrepared,
      sourceOffset,
      displayTree?.formulas.length ?? 0,
    );
    final cached = _cache.get(key);
    if (cached != null) {
      cacheHits++;
      return cached;
    }
    var result = _measure(
      block,
      withIndent: withIndent,
      asChapterTitle: asChapterTitle,
      sourceOffset: sourceOffset,
    );
    final tree = displayTree;
    final index = tree?.blockIndexById[block.id];
    final legend = tree?.legends[index];
    if (legend != null && result.lines.isNotEmpty) {
      final style = styleTable?[legend.element.styleId ?? 0];
      final available = result.layoutWidth ?? options.contentWidth;
      final width = style?.size.width == null
          ? result.lines
                .fold<double>(0, (v, l) => math.max(v, l.left + l.width))
                .clamp(1.0, available)
          : available;
      final margin = style?.block.margin;
      final offset = margin?.left?.isAuto == true
          ? (available - width) / (margin?.right?.isAuto == true ? 2 : 1)
          : 0;
      result = result.withBoxEdges(
        first: result.boxFirst,
        last: result.boxLast,
        contentInset: result.inset + offset,
        contentWidth: width,
        legendFieldset: legend.parent!.element.id,
      );
    }
    final pageTop = DisplayPosition.topOf(
      _styleOf(block).computed,
      options,
      result.height,
      tree: displayTree,
      index: displayTree?.blockIndexById[block.id],
      styles: styleTable,
    );
    if (pageTop != null && sourceOffset == 0) {
      result = result.withBoxEdges(
        first: result.boxFirst,
        last: result.boxLast,
        pageTop: pageTop,
      );
    }
    measuredBlocks++;
    _cache.put(key, result);
    return result;
  }

  /// 取这一块的排版样式：块上的 `styleId` 指向本章样式表，缺省就是默认样式。
  ResolvedBlockStyle _styleOf(
    ContentBlock block, {
    int sourceOffset = 0,
    int? sourceEnd,
  }) {
    final base = styleTable?[block.styleId ?? 0] ?? ComputedStyle.empty;
    final index = displayTree?.blockIndexById[block.id];
    final owner = index == null
        ? null
        : displayTree?.source?.ownerOfBlock(index);
    final own = styleTable?[owner?.styleId ?? 0];
    var computed =
        displayTree?.authoritative != true || owner == null || own == null
        ? base
        : ComputedStyle(
            text: own.text,
            box: own.box,
            block: own.block,
            size: own.size,
            table: own.table,
          );
    // 块内显示范围也有自己的段落对齐、字距和阴影；正文归属不变，不能
    // 为了保留原块号而把这些布局属性仍固定读成外层 p 的样式。
    if (index != null && sourceEnd != null) {
      for (final node
          in (displayTree?.flows[index] ?? const <DisplayNode>[]).toSet()) {
        if (node.element.ranges.any(
          (r) =>
              r.block == index && r.start <= sourceOffset && r.end >= sourceEnd,
        )) {
          final flow = styleTable?[node.element.styleId ?? 0];
          if (flow != null) {
            computed = ComputedStyle(
              text: flow.text,
              box: computed.box,
              block: flow.block.mergeOver(computed.block),
              size: flow.size,
              table: flow.table,
            );
          }
        }
      }
    }
    return ResolvedBlockStyle.fromStyle(
      block,
      computed,
      nestOverride: flatNest ? 0 : null,
      context: _lengthContext(computed, options.contentWidth),
    );
  }

  /// 把片段按 `styleId` 补回显示属性（粗体、颜色、下划线、上下标、相对字号）。
  ///
  /// 返回的是显示副本，`styleId`、链接和脚注标记原样保留；没有样式表的旧正文
  /// 仍按片段自带字段显示（见 [ResolvedRunStyle.of]）。
  List<TextRun> _resolveRuns(List<TextRun> runs) => [
    for (final run in runs) _runStyleOf(run).applyTo(run),
  ];

  ResolvedRunStyle _runStyleOf(TextRun run) => ResolvedRunStyle.of(
    run,
    styleTable,
    tableFontRoot: authorTableCell
        ? options.settings.fontSize.toDouble()
        : null,
  );

  MeasuredBlock _measure(
    ContentBlock block, {
    required bool withIndent,
    required bool asChapterTitle,
    required int sourceOffset,
  }) {
    switch (block.kind) {
      case BlockKind.image:
        return _measureImage(block);
      case BlockKind.divider:
        return _measureDivider(block);
      case BlockKind.heading:
      case BlockKind.paragraph:
      case BlockKind.listItem:
      case BlockKind.quote:
      case BlockKind.codeBlock:
      case BlockKind.caption:
      case BlockKind.footnote:
        if (!asChapterTitle) {
          return _measureText(
            block,
            withIndent: withIndent,
            sourceOffset: sourceOffset,
          );
        }
        final measured = _measureText(block, withIndent: false, styleLevel: 0);
        return MeasuredBlock(
          blockId: measured.blockId,
          kind: measured.kind,
          level: measured.level,
          text: measured.text,
          runs: measured.runs,
          runStyles: measured.runStyles,
          lines: measured.lines,
          // 章题整体高度：文字 + 间隔 + 短分隔线
          height: measured.height + kTitleRuleGap + kTitleRuleThickness,
          inset: measured.inset,
          layoutWidth: measured.layoutWidth,
          isTitleDecoration: true,
          // 书内的对齐、列表标记、上下标等显示属性同样要带过来
          align: measured.align,
          justify: measured.justify,
          marker: measured.marker,
          markerInset: measured.markerInset,
          hasScript: measured.hasScript,
          displayPrefixLength: measured.displayPrefixLength,
          // 书内样式表给的盒子（彩色章题横幅）也要保留
          box: measured.box,
          boxId: measured.boxId,
          boxIndent: measured.boxIndent,
          bodyTop: measured.bodyTop,
          bodyBottom: measured.bodyBottom,
          textStyle: measured.textStyle,
          inlineImages: measured.inlineImages,
          inlineBoxes: measured.inlineBoxes,
        );
    }
  }

  /// 章题装饰块：正文区顶部的章名 + 短分隔线（参考图 03 的章首样式）。
  /// 只在正文首块不是同名标题时使用（见 `ChapterLayout`）。
  MeasuredBlock measureChapterTitle(String title) {
    final block = ContentBlock(
      id: titleBlockId,
      kind: BlockKind.heading,
      level: 1,
      runs: [TextRun(title)],
    );
    final measured = _measureText(block, withIndent: false, styleLevel: 0);
    return MeasuredBlock(
      blockId: titleBlockId,
      kind: BlockKind.heading,
      level: 0,
      text: measured.text,
      runs: measured.runs,
      runStyles: measured.runStyles,
      lines: measured.lines,
      // 章题整体判定：文字 + 间隔 + 短分隔线
      height: measured.height + kTitleRuleGap + kTitleRuleThickness,
      inset: 0,
      isDecoration: true,
      isTitleDecoration: true,
    );
  }

  static String? _markerOf(BlockKind kind, ResolvedBlockStyle style) {
    if (kind != BlockKind.listItem) return null;
    final listStyle = style.listStyle;
    if (listStyle == 0) return null;
    final ordinal = style.ordinal ?? 1;
    return switch (listStyle) {
      1 => '$ordinal.',
      2 => '${_alphaMarker(ordinal)}.',
      3 => '${_alphaMarker(ordinal).toUpperCase()}.',
      4 => '${_romanMarker(ordinal)}.',
      5 => '${_romanMarker(ordinal).toUpperCase()}.',
      6 => '•',
      7 => '○',
      8 => '▪',
      _ => style.ordered ? '$ordinal.' : '•',
    };
  }

  /// 1 → a、2 → b …… 26 → z、27 → aa（CSS 的小写字母序号）
  static String _alphaMarker(int number) {
    var value = number < 1 ? 1 : number;
    final buffer = StringBuffer();
    while (value > 0) {
      value -= 1;
      buffer.writeCharCode(0x61 + value % 26);
      value ~/= 26;
    }
    return String.fromCharCodes(buffer.toString().codeUnits.reversed);
  }

  /// 1 → i、4 → iv、9 → ix（CSS 的小写罗马数字序号）
  static String _romanMarker(int number) {
    var value = number.clamp(1, 3999);
    const values = [1000, 900, 500, 400, 100, 90, 50, 40, 10, 9, 5, 4, 1];
    const symbols = [
      'm',
      'cm',
      'd',
      'cd',
      'c',
      'xc',
      'l',
      'xl',
      'x',
      'ix',
      'v',
      'iv',
      'i',
    ];
    final buffer = StringBuffer();
    for (var i = 0; i < values.length; i++) {
      while (value >= values[i]) {
        buffer.write(symbols[i]);
        value -= values[i];
      }
    }
    return buffer.toString();
  }

  ///
  /// 把硬换行位置上的空格替换成换行符。
  ///
  /// 1:1 替换：文字长度不变，所以选区、书签、笔记和朗读位置都仍然有效。
  /// [offset] 是前缀长度——前缀只加在第一个 run 上，换行位置要跟着平移。
  static List<TextRun> _withBreaks(
    List<TextRun> runs,
    List<int> breaks,
    int offset,
  ) {
    final result = <TextRun>[];
    var cursor = 0;
    var next = 0;
    for (final run in runs) {
      final start = cursor;
      final end = cursor + run.text.length;
      cursor = end;
      if (end <= start) {
        result.add(run);
        continue;
      }
      final buffer = StringBuffer();
      var changed = false;
      for (var i = start; i < end; i++) {
        final index = i - offset;
        if (next < breaks.length && breaks[next] == index) {
          buffer.write('\n');
          next++;
          changed = true;
        } else {
          buffer.write(run.text[i - start]);
        }
      }
      result.add(
        changed
            ? TextRun(
                buffer.toString(),
                bold: run.bold,
                italic: run.italic,
                superscript: run.superscript,
                subscript: run.subscript,
                color: run.color,
                sizeScale: run.sizeScale,
                underline: run.underline,
                strike: run.strike,
                link: run.link,
                footnote: run.footnote,
                styleId: run.styleId,
              )
            : run,
      );
    }
    return result;
  }

  /// 取 [start, end) 区间的文字片段。
  static List<InlineSpan> _slice(
    List<TextRun> runs,
    List<TextStyle> styles,
    int start,
    int end, {
    int fixedPrefixLength = 0,
    double? letterSpacing,
  }) {
    final spans = <InlineSpan>[];
    var cursor = 0;
    for (var i = 0; i < runs.length; i++) {
      final runStart = cursor;
      final runEnd = cursor + runs[i].text.length;
      cursor = runEnd;
      if (runEnd <= start || runStart >= end) continue;
      final from = (start > runStart ? start : runStart) - runStart;
      final to = (end < runEnd ? end : runEnd) - runStart;
      if (to <= from) continue;
      final split = (fixedPrefixLength - runStart).clamp(from, to);
      if (split > from) {
        spans.add(
          FixedIndent.span(runs[i].text.substring(from, split), styles[i]),
        );
      }
      if (to > split) {
        spans.add(
          TextSpan(
            text: runs[i].text.substring(split, to),
            style: letterSpacing == null
                ? styles[i]
                : styles[i].copyWith(letterSpacing: letterSpacing),
          ),
        );
      }
    }
    return spans;
  }

  /// 等宽字体下一个空格的宽度（代码缩进按它换算成像素）。
  double _spaceWidth(TextStyle style) {
    final cached = _spaceWidths[style];
    if (cached != null) return cached;
    final painter = TextPainter(
      text: TextSpan(text: ' ', style: style),
      textDirection: TextDirection.ltr,
      textScaler: options.textScaler,
    )..layout();
    final width = painter.width;
    painter.dispose();
    _spaceWidths[style] = width;
    return width;
  }

  final _spaceWidths = <TextStyle, double>{};

  ///
  /// 取第 [index] 行的起始偏移。
  ///
  /// 用行内位置向排版引擎查询逻辑行首。双向文字的视觉左端可能是本行结尾。
  int _lineStartAt(
    TextPainter painter,
    List<LineMetrics> metrics,
    int index,
    int fallback, {
    bool simpleLtr = false,
  }) {
    // 不累计行盒高度猜字形位置：混合字体的基线不同，应直接用该行真实基线。
    final y = metrics[index].baseline - metrics[index].ascent / 2;
    if (simpleLtr) {
      return math.max(
        fallback,
        painter.getPositionForOffset(Offset(0, y)).offset,
      );
    }
    final line = metrics[index];
    final interior = painter.getPositionForOffset(
      Offset(line.left + line.width / 2, y),
    );
    final start = painter.getLineBoundary(interior).start;
    return math.max(fallback, start);
  }

  /// 把祖先容器换算成这一块上的外框，供背景、边框和圆角绘制。
  ///
  /// 文字、图片和分隔线都要带同一份容器链；否则最后一块是 `<hr>` 时，
  /// 外层盒子找不到“最后一块”，底边就不会画。
  List<ContainerBoxFrame> _containerFramesOf(
    _BlockInset spacing,
    double contentWidth,
  ) {
    return spacing.frames;
  }

  ///
  /// 图片块按内容宽度等比缩放；超过一页正文高度时缩到能放进一页，不裁切
  /// （实现计划第 10 节决定 1）。
  ///
  /// 把缩进前缀加入 runs，让「块文本 == runs 拼接」始终成立。
  static List<TextRun> _withPrefix(
    List<TextRun> runs,
    String prefix, {
    bool separate = false,
  }) {
    if (prefix.isEmpty) return runs;
    if (runs.isEmpty) return [TextRun(prefix)];
    final first = runs.first;
    // 下划线／删除线不能盖住首行缩进：原书用 text-indent 缩进首行，装饰线只从
    // 真正的文字开始。首字需要独立的符号字体时，也让缩进单独成段。
    if (separate || first.underline || first.strike) {
      return [
        TextRun(
          prefix,
          bold: first.bold,
          italic: first.italic,
          superscript: first.superscript,
          subscript: first.subscript,
          color: first.color,
          sizeScale: first.sizeScale,
        ),
        first,
        ...runs.skip(1),
      ];
    }
    return [
      TextRun(
        prefix + first.text,
        bold: first.bold,
        italic: first.italic,
        superscript: first.superscript,
        subscript: first.subscript,
        color: first.color,
        sizeScale: first.sizeScale,
        underline: first.underline,
        strike: first.strike,
        link: first.link,
        footnote: first.footnote,
        styleId: first.styleId,
      ),
      ...runs.skip(1),
    ];
  }

  /// 字号等参数变化后重新构造测量器（缓存键已包含全部参数，无需手动失效）
  BlockMeasurer withOptions(
    LayoutOptions next, {
    bool? normalFlow,
    ({int elementId, double width})? floatContentWidth,
  }) => BlockMeasurer(
    next,
    styleTable: styleTable,
    displayTree: displayTree,
    formulaTree: formulaTree,
    flatNest: flatNest,
    authorTableCell: authorTableCell,
    tableBody: tableBody,
    normalFlow: normalFlow ?? this.normalFlow,
    floatContentWidth: floatContentWidth,
    paginated: paginated,
    cache: _cache,
  );
}

/// 便于测试与调用方直接拿到默认设置
const ReadingSettings kDefaultReadingSettings = ReadingSettings();
