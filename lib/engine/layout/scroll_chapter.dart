import 'dart:math' as math;
import 'dart:ui' show Rect;

import '../../domain/models/book_document.dart';
import '../../domain/models/locator.dart';
import '../normalization/locator_mapper.dart';
import '../styles/chapter_styler.dart';
import '../styles/css_layout_styles.dart';
import 'block_measure.dart';
import 'block_measurement_cache.dart';
import 'english_hyphenation.dart';
import 'layout_options.dart';
import 'measured_block.dart';
import 'chapter_layout.dart';
import 'chapter_paginator.dart';
import 'display_tree.dart';
import 'table_layout.dart';
import 'parallel_flow_layout.dart';

/// 连续正文的一小段行。保留原块和偏移，不以临时行号保存阅读位置。
class ScrollCell {
  ScrollCell(
    this.block,
    this.measured,
    this.offset,
    this.from,
    this.to,
    this.gap, {
    this.endGap = 0,
    this.table = const [],
    this.tableHeight,
  });
  final ContentBlock block;
  final MeasuredBlock measured;
  final int offset, from, to;
  final double gap;
  final double endGap;
  final List<PageFragment> table;
  final double? tableHeight;
  // 单元格完成测量后不再变化，列表反复查询高度时不再复制并遍历文字行。
  late final double height = tableHeight != null
      ? tableHeight! + endGap
      : gap +
            endGap +
            (from == 0 && measured.isText ? measured.bodyTop : 0) +
            (to == measured.lines.length && measured.isText
                ? measured.bodyBottom
                : 0) +
            (measured.isText
                ? measured.lines
                      .sublist(from, to)
                      .fold<double>(0, (n, l) => n + l.height)
                : measured.height) +
            (measured.isTitleDecoration && to == measured.lines.length
                ? kTitleRuleGap + kTitleRuleThickness
                : 0);

  /// 首批文字要跳过容器内边距；定位、选文与绘制共用这个起点。
  double get textTop => gap + (from == 0 ? measured.bodyTop : 0);

  /// 块级图片共用分页的居中和容器内边距；坐标相对当前滚动单元格。
  Iterable<({MeasuredBlock block, Rect rect})> positionedImages(
    double width,
  ) sync* {
    if (table.isNotEmpty) {
      for (final fragment in table) {
        final rect = fragment.imageRectIn(width);
        if (rect != null) yield (block: fragment.block, rect: rect);
      }
    } else {
      final rect = measured.imageRectIn(width, top: gap);
      if (rect != null) yield (block: measured, rect: rect);
    }
  }

  /// 绘制和点按共用片段坐标，普通正文与表格内的公式走同一条路径。
  Iterable<({InlineImagePlacement image, Rect rect})>
  get positionedInlineImages sync* {
    if (table.isNotEmpty) {
      for (final fragment in table) {
        yield* fragment.positionedInlineImages;
      }
    } else {
      yield* PageFragment(
        block: measured,
        lineFrom: from,
        lineTo: to,
        y: gap,
        height: height - gap - endGap,
      ).positionedInlineImages;
    }
  }

  int offsetAt(int line) =>
      offset + measured.lines[line].start - measured.displayPrefixLength;
}

/// 只测量一个章节；超长段以小段测量并保留末行，下一批接着排，避免截断行。
class ScrollChapter {
  ScrollChapter(
    this.content,
    this.cells,
    this.starts,
    this.height, {
    this.options,
  });
  final LayoutOptions? options;
  final ChapterContent content;
  final List<ScrollCell> cells;
  final List<double> starts;
  final double height;

  static Future<ScrollChapter> prepare(
    ChapterContent content,
    LayoutOptions options, {
    required bool Function() cancelled,
    String chapterTitle = '',
    BlockMeasurementCache? measurementCache,
  }) async {
    final cells = <ScrollCell>[];
    final starts = <double>[];
    content = CssLayoutStyles.resolve(content, options);
    await EnglishHyphenation.prepare();
    final measurer = BlockMeasurer(
      options,
      styleTable: ChapterStyler.layoutTableOf(content),
      displayTree: DisplayTree.build(content),
      cache: measurementCache,
    );
    var height = 0.0;
    await measurer.prepareMath(content);
    double gapFor(MeasuredBlock block, double initial) {
      final gap = cells.isEmpty
          ? math.max(initial, block.marginTop)
          : measurer.gapBefore(cells.last.measured, block);
      return block.pageTop == null
          ? gap
          : math.max(gap, block.pageTop! - height);
    }

    void add(ScrollCell cell) {
      starts.add(height);
      cells.add(cell);
      height += cell.height;
    }

    final work = Stopwatch()..start();
    final byId = {for (final block in content.blocks) block.id: block};
    final tables = {
      for (final table in content.tables) table.blockIds.first: table,
    };
    final tableIds = content.tables.expand((t) => t.blockIds).toSet();
    final parallel = ParallelFlowLayout(
      content,
      measurer.displayTree!,
      ChapterStyler.layoutTableOf(content),
      options,
    );
    // 章题和短横线只给 TXT 补；其他格式按原书内容排，不插入标题。
    final contentTitle =
        options.insertChapterTitle &&
        ChapterLayout.firstBlockIsChapterTitle(content, chapterTitle);
    if (options.insertChapterTitle &&
        content.pdfPage == null &&
        !contentTitle &&
        chapterTitle.trim().isNotEmpty) {
      final title = measurer.measureChapterTitle(chapterTitle);
      add(
        ScrollCell(
          ContentBlock(
            id: title.blockId,
            kind: BlockKind.heading,
            runs: title.runs,
          ),
          title,
          0,
          0,
          title.lines.length,
          0,
        ),
      );
    }
    for (final (blockIndex, block) in content.blocks.indexed) {
      for (final empty in measurer.measureBefore(blockIndex)) {
        add(ScrollCell(block, empty, 0, 0, 0, 0));
      }
      if (tables.containsKey(block.id) ||
          parallel.groups.containsKey(blockIndex)) {
        final measured = parallel.groups.containsKey(blockIndex)
            ? parallel.measure(blockIndex, measurer)
            : measureTable(
                tables[block.id]!,
                byId,
                options,
                cache: measurementCache,
                styleTable: ChapterStyler.layoutTableOf(content),
                displayTree: measurer.displayTree,
                order: content.blocks,
              );
        final total = tableHeight(measured);
        var from = 0.0;
        while (from < total - .1) {
          // 连续滚动不需要用分页高度切双列，保留完整二维位置即可。
          final to = measured.first.isParallelFlow
              ? total
              : tableCut(measured, from, options.contentHeight);
          final end = to > from
              ? to
              : math.min(total, from + measured.first.tableUnit);
          final gap = from == 0
              ? gapFor(measured.first, options.paragraphGap)
              : 0.0;
          final fragments = tableFragments(measured, from, end, gap);
          final first = fragments.firstWhere(
            (f) => !f.frameOnly,
            orElse: () => fragments.first,
          );
          add(
            ScrollCell(
              byId[first.block.blockId] ?? block,
              first.block,
              0,
              first.lineFrom,
              first.lineTo,
              0,
              table: fragments,
              tableHeight: end - from + gap,
            ),
          );
          from = end;
        }
        await Future<void>.delayed(Duration.zero);
      }
      if (tableIds.contains(block.id) ||
          parallel.members.contains(blockIndex)) {
        continue;
      }
      final text = blockTextOf(block);
      var offset = 0;
      var first = true;
      do {
        if (cancelled()) throw const ScrollPreparationCancelled();
        final end = block.kind == BlockKind.codeBlock
            ? text.length
            : measurer.formulaSafeEnd(
                block,
                snapToGrapheme(text, math.min(text.length, offset + 2048)),
              );
        final piece = text.length <= 2048 || block.kind == BlockKind.codeBlock
            ? block
            : ContentBlock(
                id: block.id,
                kind: block.kind,
                level: block.level,
                runs: _runsIn(block.runs, offset, end),
                // 样式不在块上：分段时把样式编号原样带上，测量才取得到同一份样式。
                styleId: block.styleId,
                isQuoteContainer: block.isQuoteContainer,
                boxId: block.boxId,
                parentBox: block.parentBox,
                inlineBoxes: [
                  for (final span in block.inlineBoxes)
                    if (span.start < end && span.end > offset)
                      InlineBoxSpan(
                        start: math.max(0, span.start - offset),
                        end: math.min(end, span.end) - offset,
                        id: span.id,
                        box: span.box,
                        scale: span.scale,
                        styleId: span.styleId,
                        first: span.first && span.start >= offset,
                        last: span.last && span.end <= end,
                      ),
                ],
                // 长段分批测量时，行内图片要跟着所在文字一起移动
                inlineImages: [
                  for (final image in block.inlineImages)
                    if (image.offset >= offset && image.offset < end)
                      InlineImage(
                        offset: image.offset - offset,
                        resourcePath: image.resourcePath,
                        width: image.width,
                        height: image.height,
                        imageWidth: image.imageWidth,
                        imageMaxWidth: image.imageMaxWidth,
                        alt: image.alt,
                        styleId: image.styleId,
                      ),
                ],
              );
        var measured = measurer.measure(
          piece,
          sourceOffset: offset,
          withIndent:
              first &&
              options.settings.indent &&
              (block.kind == BlockKind.paragraph ||
                  block.kind == BlockKind.quote),
          asChapterTitle: contentTitle && block == content.blocks.first,
        );
        if (measured.boxId != null && measured.box != null) {
          final index = content.blocks.indexOf(block);
          int? containerOf(ContentBlock value) =>
              value.parentBox?.id ?? value.boxId;
          measured = measured.asBoxPart(
            first:
                first &&
                (index == 0 ||
                    containerOf(content.blocks[index - 1]) != measured.boxId),
            last:
                end == text.length &&
                (index + 1 == content.blocks.length ||
                    containerOf(content.blocks[index + 1]) != measured.boxId),
          );
        }
        // 最后一行可能还没满，交给下一批与后续文字一起测量。
        final count =
            measured.lines.length -
            (end < text.length && measured.lines.length > 1 ? 1 : 0);
        if (!measured.isText) {
          add(
            ScrollCell(
              block,
              measured,
              0,
              0,
              0,
              gapFor(measured, options.paragraphGap),
            ),
          );
          break;
        }
        for (var line = 0; line < count; line += 12) {
          add(
            ScrollCell(
              block,
              measured,
              offset,
              line,
              math.min(count, line + 12),
              first &&
                      line == 0 &&
                      (block != content.blocks.first || !contentTitle)
                  ? gapFor(measured, options.paragraphGap)
                  : 0,
            ),
          );
        }
        offset += measured.lines[count - 1].end - measured.displayPrefixLength;
        first = false;
        // 给触摸和绘制让出执行机会，不一次排完整个长章。
        if (work.elapsedMicroseconds >= 3000) {
          await Future<void>.delayed(Duration.zero);
          work.reset();
        }
      } while (offset < text.length);
    }
    // 章尾只留两行正文高度；留白不另造正文块，已有位置和笔记仍指向原文。
    if (cells.isNotEmpty) {
      final last = cells.removeLast();
      final gap =
          options.textScaler.scale(options.settings.fontSize.toDouble()) *
          options.settings.lineHeight *
          2;
      cells.add(
        ScrollCell(
          last.block,
          last.measured,
          last.offset,
          last.from,
          last.to,
          last.gap,
          endGap: gap,
          table: last.table,
          tableHeight: last.tableHeight,
        ),
      );
      height += gap;
    }
    if (content.blocks.isNotEmpty) {
      for (final empty in measurer.measureBefore(content.blocks.length)) {
        add(ScrollCell(content.blocks.last, empty, 0, 0, 0, 0));
      }
    }
    return ScrollChapter(content, cells, starts, height, options: options);
  }

  Locator anchorAt(double y, LocatorMapper mapper) {
    final i = cellAt(y);
    final cell = cells[i];
    if (cell.table.isNotEmpty) {
      final parts = cell.table.where((f) => !f.frameOnly).toList();
      if (parts.isEmpty) return mapper.at(cell.block, 0);
      final fragment =
          parts.where((f) => f.y + f.height > y - starts[i]).firstOrNull ??
          parts.last;
      final block = content.blocks.firstWhere(
        (b) => b.id == fragment.block.blockId,
      );
      return mapper.at(
        block,
        fragment.block.lines.isEmpty
            ? 0
            : fragment.block.lines[fragment.lineFrom].start,
      );
    }
    if (cell.measured.isDecoration) return mapper.chapterStart(content.blocks);
    if (!cell.measured.isText) {
      return mapper.at(cell.block, 0, affinity: LocatorAffinity.before);
    }
    var top = starts[i] + cell.textTop;
    var line = cell.from;
    while (line + 1 < cell.to &&
        top + cell.measured.lines[line].height <= y + 0.00001) {
      top += cell.measured.lines[line++].height;
    }
    return mapper.at(
      cell.block,
      cell.offsetAt(line).clamp(0, blockTextOf(cell.block).length),
    );
  }

  int cellAt(double y) {
    var lo = 0, hi = starts.length;
    while (lo < hi) {
      final mid = (lo + hi) ~/ 2;
      if (starts[mid] <= y) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return (lo - 1).clamp(0, starts.length - 1);
  }

  double offsetOf(Locator anchor) {
    // 章首正文对应补画的标题；装饰标题本身不写入阅读位置。
    if (content.blocks.isNotEmpty &&
        anchor.blockId == content.blocks.first.id &&
        anchor.utf16Offset == 0 &&
        cells.first.measured.isTitleDecoration) {
      return 0;
    }
    for (var i = 0; i < cells.length; i++) {
      final cell = cells[i];
      if (cell.table.isNotEmpty) {
        for (final fragment in cell.table) {
          if (fragment.frameOnly || fragment.block.blockId != anchor.blockId) {
            continue;
          }
          final lines = fragment.block.lines;
          if (lines.isEmpty ||
              (anchor.utf16Offset >= lines[fragment.lineFrom].start &&
                  anchor.utf16Offset <= lines[fragment.lineTo - 1].end)) {
            return starts[i] + fragment.y;
          }
        }
        continue;
      }
      if (cell.block.id != anchor.blockId) continue;
      if (!cell.measured.isText) return starts[i];
      var top = starts[i] + cell.textTop;
      for (var line = cell.from; line < cell.to; line++) {
        final end =
            cell.offset +
            cell.measured.lines[line].end -
            cell.measured.displayPrefixLength;
        if (anchor.utf16Offset < end) return top;
        top += cell.measured.lines[line].height;
      }
    }
    return height;
  }

  static List<TextRun> _runsIn(List<TextRun> runs, int from, int to) {
    final result = <TextRun>[];
    var start = 0;
    for (final run in runs) {
      final end = start + run.text.length;
      if (end > from && start < to) {
        result.add(
          TextRun(
            run.text.substring(
              math.max(0, from - start),
              math.min(run.text.length, to - start),
            ),
            bold: run.bold,
            italic: run.italic,
            color: run.color,
            sizeScale: run.sizeScale,
            superscript: run.superscript,
            subscript: run.subscript,
            underline: run.underline,
            strike: run.strike,
            link: run.link,
            footnote: run.footnote,
            styleId: run.styleId,
          ),
        );
      }
      start = end;
    }
    return result;
  }
}

class ScrollPreparationCancelled implements Exception {
  const ScrollPreparationCancelled();
}
