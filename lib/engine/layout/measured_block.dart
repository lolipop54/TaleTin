/// 单块的测量结果：分页只做算术，不再碰 TextPainter（实现计划 4 / 5.6）。
///
/// 关键不变量：把 [lines] 按顺序取文本拼起来，等于 [text]。
/// 分页切分只按行边界走，因此「整章所有页拼起来 == 标准化正文」是结构性成立的，
/// 不依赖任何事后回填。
library;

import 'package:flutter/painting.dart';

import 'edge_aligned_text_painter.dart';

import '../../domain/models/book_document.dart';

/// 一行在块文本中的范围与高度。
class MeasuredLine {
  const MeasuredLine({
    required this.start,
    required this.end,
    required this.height,
    required this.width,
    this.hyphenated = false,
  });

  /// 行首偏移（UTF-16 code unit，相对整块文本）
  final int start;

  /// 行尾偏移；下一行的 start 就是本行的 end
  final int end;

  /// 行盒高度（像素）
  final double height;

  /// 这一行实际占用的宽度（像素，来自 `LineMetrics.width`）。
  ///
  /// 与内容宽度之差就是这一行的「空档」：多数行是「下一个字放不下」造成的
  /// 不到一个字的空档，标点避头尾时还会多出一个字的空档——绘制时按这个差值
  /// 拉开字距，行就能顶到右边（见 `createFragmentPainter` 的说明）。
  final double width;

  /// 显示层的英文断字连字符，不计入原文范围。
  final bool hyphenated;
}

/// 标题装饰块（章题）与其下短分隔线之间的间距
const double kTitleRuleGap = 12;
const double kTitleRuleThickness = 2;
const double kTitleRuleWidth = 36;

/// 分隔线块的固定高度（线居中）
const double kDividerHeight = 29;

class MeasuredBlock {
  const MeasuredBlock({
    required this.blockId,
    required this.kind,
    this.level,
    this.text = '',
    this.runs = const [],
    this.runStyles = const [],
    this.lines = const [],
    this.height = 0,
    this.imageSize,
    this.resourcePath,
    this.alt,
    this.inset = 0,
    this.isDecoration = false,
    this.displayPrefixLength = 0,
    this.isTitleDecoration = false,
    this.tableId,
    this.tableBounds,
    this.tableTop = 0,
    this.tableUnit = 0,
    this.tableHeader = false,
    this.layoutWidth,
  });

  final String blockId;
  final String? tableId;
  final Rect? tableBounds;
  final double tableTop, tableUnit;
  final bool tableHeader;
  final double? layoutWidth;

  MeasuredBlock inTable({required String id, required Rect bounds,
    required double top, required double unit, required bool header, required double width}) => MeasuredBlock(
    blockId: blockId, kind: kind, level: level, text: text, runs: runs,
    runStyles: runStyles, lines: lines, height: height, imageSize: imageSize,
    resourcePath: resourcePath, alt: alt, inset: bounds.left + 4,
    isDecoration: isDecoration, displayPrefixLength: displayPrefixLength,
    tableId: id, tableBounds: bounds, tableTop: top, tableUnit: unit,
    tableHeader: header, layoutWidth: width,
  );
  final BlockKind kind;

  /// 标题级别；0 表示章题装饰块
  final int? level;

  /// 整块文本（文本块含首行缩进前缀）
  final String text;
  final List<TextRun> runs;

  /// 与 [runs] 一一对应的完整样式（含字号、字重、行高、字体）
  final List<TextStyle> runStyles;

  final List<MeasuredLine> lines;

  /// 整块高度（文本块 = 各行高度之和）
  final double height;

  /// 图片块的显示尺寸（已按内容宽度等比缩放）
  final Size? imageSize;
  final String? resourcePath;
  final String? alt;

  /// 列表项等块的左侧绘制偏移
  final double inset;

  /// 首行缩进前缀的字符数（0 或 2）。
  ///
  /// 缩进是**画出来的**两个全角空格，会进入 [text] 与行偏移；而 Locator 的偏移
  /// 以标准化正文为准（不含缩进），两者换算时必须减掉这个长度，否则改一次
  /// 缩进设置就会让所有位置整体偏移两个字符。
  final int displayPrefixLength;

  /// 装饰块：参与排版与绘制，但不属于正文文本流（章题、分隔线）
  final bool isDecoration;

  bool get isText => lines.isNotEmpty;

  /// 按章题样式绘制（大字号 + 下方短分隔线）。
  ///
  /// 章首那个标题有两种来源：正文里本来就有同名标题时直接把它当章题用，
  /// 避免「版权信息」这类标题重复出现两次；正文没有标题时才补一个装饰块。
  final bool isTitleDecoration;

  /// 构造绘制某段行范围用的 [TextPainter]。
  ///
  /// **绘制与测量必须共用同一套参数**：同一个 [TextScaler]（来自排版的
  /// `LayoutOptions`）与同一个 [maxWidth]。少传或传错任何一个，画出来的行就
  /// 会和排版时算出的行不一致——典型的症状是每行末尾留白、页尾那行提前结束
  /// （设计文档 6.4）。这里的 `maxWidth` 应当直接用 `LayoutOptions.contentWidthFor`
  /// 的返回值，而不是界面盒子的宽度。
  ///
  /// [letterSpacing] 用于把行尾空档摊到字与字之间（见 [justifySpacingFor]）。
  /// 它只影响绘制，不参与测量与断行。
  TextPainter createFragmentPainter({
    required int lineFrom,
    required int lineTo,
    required TextScaler textScaler,
    required double maxWidth,
    Color? color,
    double letterSpacing = 0,
  }) {
    // 拉开字距的行独立绘制，不把行外半份字距算进可用宽度或再次折行。
    if (letterSpacing > 0 && lineTo == lineFrom + 1) {
      return createSingleLinePainter(
        lineIndex: lineFrom,
        textScaler: textScaler,
        color: color,
        letterSpacing: letterSpacing,
      );
    }
    final start = lines[lineFrom].start;
    final end = lines[lineTo - 1].end;
    return TextPainter(
      text: TextSpan(children: _paintSpans(start, end, color, letterSpacing)),
      textDirection: TextDirection.ltr,
      textScaler: textScaler,
    )..layout(maxWidth: maxWidth);
  }

  /// 单行片段：不给断行宽度，排出来永远是一行。
  ///
  /// 给 [createFragmentPainter] 兜底用。行宽正好顶到内容宽、或者行尾标点在字体
  /// 回退后拿到更宽的写法时，整段重排会比测量时多折出一行，多出来的那行压在
  /// 下一行上（真机实测：两个字叠在一起，看着像少了字）。逐行画就没有这个风险。
  TextPainter createSingleLinePainter({
    required int lineIndex,
    required TextScaler textScaler,
    Color? color,
    double letterSpacing = 0,
  }) {
    final line = lines[lineIndex];
    final span = TextSpan(
      children: _paintSpans(line.start, line.end, color, letterSpacing),
    );
    if (letterSpacing > 0) {
      return EdgeAlignedTextPainter(
        text: span,
        textScaler: textScaler,
        spacing: letterSpacing,
      )..layout();
    }
    return TextPainter(
      text: TextSpan(
        children: _paintSpans(line.start, line.end, color, letterSpacing),
      ),
      textDirection: TextDirection.ltr,
      textScaler: textScaler,
    )..layout();
  }

  /// 取 [start, end) 区间用于绘制的 span，覆盖颜色与字距。
  List<InlineSpan> _paintSpans(
    int start,
    int end,
    Color? color,
    double letterSpacing,
  ) {
    return [
      for (final span in spansFor(start, end))
        TextSpan(
          text: (span as TextSpan).text,
          style: (span.style ?? const TextStyle()).copyWith(
            color: color,
            letterSpacing: letterSpacing == 0 ? null : letterSpacing,
          ),
        ),
      if (lines.any((line) => line.end == end && line.hyphenated))
        TextSpan(
          text: '-',
          style: (spansFor(start, end).last as TextSpan).style?.copyWith(
            color: color,
            letterSpacing: letterSpacing,
          ),
        ),
    ];
  }

  /// 这一行绘制时要摊开的字距（0 表示原样画）。
  ///
  /// 行尾空档有两个来源：一是常有的「下一个字放不下」（不到一个字宽），
  /// 二是中文避头尾——下一个字放得下，但它后面的标点不允许出现在行首，
  /// 于是整行提前收尾，空出整整一个到两个字。第二种在阅读时像是「少了字」，
  /// 这里按字距摊平到整行，让每一行都顶到右边。
  ///
  /// 段落最后一行和标题不拉伸；其余有空档的行都摊开，不按空档大小筛选。
  double justifySpacingFor(
    int lineIndex, {
    required double maxWidth,
    required bool enabled,
    TextScaler textScaler = TextScaler.noScaling,
  }) {
    if (!enabled || lineIndex >= lines.length - 1) return 0;
    final cache = _spacingCache[this] ??= {};
    final key = (lineIndex, maxWidth, textScaler);
    return cache.putIfAbsent(key, () {
      double width(double spacing) {
        final painter = createSingleLinePainter(
          lineIndex: lineIndex,
          textScaler: textScaler,
          letterSpacing: spacing,
        );
        final width = painter.computeLineMetrics().first.width;
        painter.dispose();
        return width;
      }

      // 用实际字体测量字距增量，避免标点压缩、混合字重和系统缩放留下空缺。
      // 缓存跟随块释放；绘制、选文与听书高亮读取同一个结果。
      final natural = width(0);
      if (natural >= maxWidth) return 0;
      final gain = width(1) - natural;
      if (gain <= 0) return 0;
      return (maxWidth - natural) / gain;
    });
  }

  static final _spacingCache =
      Expando<Map<(int, double, TextScaler), double>>();

  /// 取 [start, end) 区间的样式片段，供绘制单行使用。
  ///
  /// 直白地按 run 边界切片：一个行片段可能横跨加粗与非加粗两段
  /// （行内图片已在上游拆块，样式段不会跨块）。
  List<InlineSpan> spansFor(int start, int end) {
    if (runs.isEmpty) return const [];
    final spans = <InlineSpan>[];
    var cursor = 0;
    for (var i = 0; i < runs.length; i++) {
      final run = runs[i];
      final runStart = cursor;
      final runEnd = cursor + run.text.length;
      cursor = runEnd;
      if (runEnd <= start || runStart >= end) continue;
      final from = (start > runStart ? start : runStart) - runStart;
      final to = (end < runEnd ? end : runEnd) - runStart;
      if (to <= from) continue;
      spans.add(
        TextSpan(text: run.text.substring(from, to), style: runStyles[i]),
      );
    }
    return spans;
  }
}
