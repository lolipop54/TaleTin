/// 块测量：把 [ContentBlock] 交给 TextPainter 量成行信息（实现计划 4 / 5.6）。
///
/// 这里是引擎里少数几个直接使用 TextPainter 的地方之一；另一半是绘制时的
/// `paintPage`。两边必须用 [LayoutOptions] 给出的同一份样式与同一个宽度，
/// 否则会出现「页尾整行空白」这类 1px 级偏差（设计文档 6.4）。
library;

import 'dart:math' as math;

import 'package:flutter/painting.dart';

import '../../domain/models/book_document.dart';
import '../../domain/models/reading_settings.dart';
import 'layout_options.dart';
import 'measured_block.dart';
import 'english_hyphenation.dart';
import 'block_measurement_cache.dart';

class BlockMeasurer {
  BlockMeasurer(this.options, {BlockMeasurementCache? cache})
    : _cache = cache ?? BlockMeasurementCache();
  final BlockMeasurementCache _cache;
  // 一个测量器的排版参数固定；长章反复使用相同样式，不必逐段重新构造。
  final _styles = <(BlockKind, int?, bool, bool), TextStyle>{};
  int cacheHits = 0, measuredBlocks = 0;

  final LayoutOptions options;

  /// 章题装饰块使用的块 ID：它不是正文块，正文拼接校验时跳过。
  static const String titleBlockId = '__chapter_title__';

  /// 测量一个正文块。
  ///
  /// [withIndent] 仅对正文段落的**段首**为 true；跨页片段不带缩进，
  /// 这样测量与渲染才一致（实现计划 5.2）。
  /// [asChapterTitle] 把章首那个标题按章题样式测量（大字号 + 短分隔线）。
  MeasuredBlock measure(
    ContentBlock block, {
    bool withIndent = false,
    bool asChapterTitle = false,
  }) {
    final s = options.settings;
    // Use exact dimensions and the actual TextScaler, rather than rounded samples.
    final key = (
      block,
      options.contentSize,
      options.textScaler,
      s.fontFamily,
      s.fontSize,
      s.fontWeight,
      s.lineHeight,
      s.paragraphGapEm,
      s.indent,
      withIndent,
      asChapterTitle,
      EnglishHyphenation.isPrepared,
    );
    final cached = _cache.get(key);
    if (cached != null) {
      cacheHits++;
      return cached;
    }
    final result = _measure(
      block,
      withIndent: withIndent,
      asChapterTitle: asChapterTitle,
    );
    measuredBlocks++;
    _cache.put(key, result);
    return result;
  }

  MeasuredBlock _measure(
    ContentBlock block, {
    required bool withIndent,
    required bool asChapterTitle,
  }) {
    switch (block.kind) {
      case BlockKind.image:
        return _measureImage(block);
      case BlockKind.divider:
        return MeasuredBlock(
          blockId: block.id,
          kind: BlockKind.divider,
          height: kDividerHeight,
          isDecoration: true,
        );
      case BlockKind.heading:
      case BlockKind.paragraph:
      case BlockKind.listItem:
      case BlockKind.footnote:
        if (!asChapterTitle) {
          return _measureText(block, withIndent: withIndent);
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
          // 章题整体判定：文字 + 间隔 + 短分隔线
          height: measured.height + kTitleRuleGap + kTitleRuleThickness,
          isTitleDecoration: true,
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
      // 标题文字 + 间隔 + 短分隔线的总高度，分页时整体判定
      height: measured.height + kTitleRuleGap + kTitleRuleThickness,
      inset: 0,
      isDecoration: true,
      isTitleDecoration: true,
    );
  }

  MeasuredBlock _measureText(
    ContentBlock block, {
    required bool withIndent,
    int? styleLevel,
  }) {
    final prefix = withIndent ? options.indentPrefix : '';
    final runs = _withPrefix(block.runs, prefix);
    final styles = [
      for (final run in runs)
        _styles.putIfAbsent(
          (block.kind, styleLevel ?? block.level, run.bold, run.italic),
          () => options.textStyleFor(
            block.kind,
            level: styleLevel ?? block.level,
            bold: run.bold,
            italic: run.italic,
          ),
        ),
    ];
    final buffer = StringBuffer();
    for (final run in runs) {
      buffer.write(run.text);
    }
    final text = buffer.toString();
    final width = options.contentWidthFor(block.kind);

    if (text.isEmpty) {
      // 空块（例如只有样式的容器）：留一个行高的位置，不画任何东西
      return MeasuredBlock(
        blockId: block.id,
        kind: block.kind,
        level: block.level,
        text: text,
        runs: runs,
        runStyles: styles,
        height: options.settings.fontSize * options.settings.lineHeight,
        inset: options.insetFor(block.kind),
      );
    }

    final display = EnglishHyphenation.display(text);
    var cursor = 0;
    final displayRuns = [
      for (final run in runs)
        display.text.substring(
          display.displayOffset(cursor),
          display.displayOffset(cursor += run.text.length),
        ),
    ];
    final painter = TextPainter(
      text: TextSpan(
        children: [
          for (var i = 0; i < runs.length; i++)
            TextSpan(text: displayRuns[i], style: styles[i]),
        ],
      ),
      textDirection: TextDirection.ltr,
      textScaler: options.textScaler,
    )..layout(maxWidth: width);

    final metrics = painter.computeLineMetrics();
    final lines = <MeasuredLine>[];
    var total = 0.0;
    for (var i = 0; i < metrics.length; i++) {
      final height = metrics[i].height;
      total += height;
      final start = i == 0 ? 0 : lines[i - 1].end;
      final displayEnd = i == metrics.length - 1
          ? display.text.length
          : _lineStartAt(painter, metrics, i + 1, display.displayOffset(start));
      final end = display.sourceOffset(displayEnd);
      lines.add(
        MeasuredLine(
          start: start,
          end: end,
          height: height,
          width: metrics[i].width,
          hyphenated:
              i < metrics.length - 1 &&
              displayEnd > 0 &&
              display.insertions.contains(displayEnd - 1),
        ),
      );
    }
    painter.dispose();

    return MeasuredBlock(
      blockId: block.id,
      kind: block.kind,
      level: block.level,
      text: text,
      runs: runs,
      runStyles: styles,
      lines: lines,
      height: total,
      inset: options.insetFor(block.kind),
      displayPrefixLength: prefix.length,
    );
  }

  /// 取第 [index] 行的起始偏移。
  ///
  /// 行起点用「该行垂直中点、水平最左」这一位置的字符位置来取；取到的位置必然
  /// 落在字素簇边界上，并且与前一行结尾天然衔接，保证拼回来不漏字、不重复。
  int _lineStartAt(
    TextPainter painter,
    List<LineMetrics> metrics,
    int index,
    int fallback,
  ) {
    // 不累计行盒高度猜字形位置：混合字体的基线不同，应直接用该行真实基线。
    final y = metrics[index].baseline - metrics[index].ascent / 2;
    final position = painter.getPositionForOffset(Offset(0, y));
    // 防御：极端情况下拿到的位置不比上一行前进时，退回上一行行尾
    return position.offset > fallback ? position.offset : fallback;
  }

  /// 图片块按内容宽度等比缩放；超过一页正文高度时缩到能放进一页，不裁切
  /// （实现计划第 10 节决定 1）。
  MeasuredBlock _measureImage(ContentBlock block) {
    final rawWidth = (block.resourceWidth ?? 0).toDouble();
    final rawHeight = (block.resourceHeight ?? 0).toDouble();
    // 尺寸嗅探失败时按 1:1 兜底（设计文档 6.2）
    final width = rawWidth > 0 ? rawWidth : options.contentWidth;
    final height = rawHeight > 0 ? rawHeight : width;

    final maxWidth = options.contentWidth;
    final maxHeight = options.contentHeight;
    var scale = math.min(1.0, maxWidth / width);
    if (height * scale > maxHeight) {
      scale = math.min(scale, maxHeight / height);
    }
    final size = Size(width * scale, height * scale);
    return MeasuredBlock(
      blockId: block.id,
      kind: BlockKind.image,
      imageSize: size,
      resourcePath: block.resourcePath,
      alt: block.alt,
      height: size.height,
    );
  }

  /// 把缩进前缀并进第一个 run，让「块文本 == runs 拼接」始终成立。
  static List<TextRun> _withPrefix(List<TextRun> runs, String prefix) {
    if (prefix.isEmpty) return runs;
    if (runs.isEmpty) return [TextRun(prefix)];
    return [
      TextRun(
        prefix + runs.first.text,
        bold: runs.first.bold,
        italic: runs.first.italic,
      ),
      ...runs.skip(1),
    ];
  }

  /// 块之间是否需要段距：表格外的所有文本块之间都补，图片与分隔线自带留白。
  double gapBefore(MeasuredBlock previous, MeasuredBlock current) {
    if (previous.isDecoration && previous.kind == BlockKind.divider) return 0;
    if (current.kind == BlockKind.divider) return options.paragraphGap;
    return options.gapBefore(previous.kind, current.kind) ??
        options.paragraphGap;
  }

  /// 字号等参数变化后重新构造测量器（缓存键已包含全部参数，无需手动失效）
  BlockMeasurer withOptions(LayoutOptions next) =>
      BlockMeasurer(next, cache: _cache);
}

/// 便于测试与调用方直接拿到默认设置
const ReadingSettings kDefaultReadingSettings = ReadingSettings();
