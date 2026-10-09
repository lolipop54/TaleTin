import 'dart:math' as math;

import '../../domain/models/book_document.dart';
import '../../domain/models/locator.dart';
import '../normalization/locator_mapper.dart';
import 'block_measure.dart';
import 'english_hyphenation.dart';
import 'layout_options.dart';
import 'measured_block.dart';
import 'chapter_layout.dart';
import 'chapter_paginator.dart';
import 'table_layout.dart';

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
  late final double height =
      tableHeight != null ? tableHeight! + endGap : gap + endGap +
      (measured.isText
          ? measured.lines
                .sublist(from, to)
                .fold<double>(0, (n, l) => n + l.height)
          : measured.height) +
      (measured.isTitleDecoration && to == measured.lines.length
          ? kTitleRuleGap + kTitleRuleThickness : 0);
  int offsetAt(int line) =>
      offset + measured.lines[line].start - measured.displayPrefixLength;
}

/// 只测量一个章节；超长段以小段测量并保留末行，下一批接着排，避免截断行。
class ScrollChapter {
  ScrollChapter(this.content, this.cells, this.starts, this.height);
  final ChapterContent content;
  final List<ScrollCell> cells;
  final List<double> starts;
  final double height;

  static Future<ScrollChapter> prepare(
    ChapterContent content,
    LayoutOptions options, {
    required bool Function() cancelled,
    String chapterTitle = '',
  }) async {
    final cells = <ScrollCell>[];
    final starts = <double>[];
    await EnglishHyphenation.prepare();
    final measurer = BlockMeasurer(options);
    var height = 0.0;
    void add(ScrollCell cell) {
      starts.add(height);
      cells.add(cell);
      height += cell.height;
    }

    final work = Stopwatch()..start();
    final byId = {for (final block in content.blocks) block.id: block};
    final tables = {for (final table in content.tables) table.blockIds.first: table};
    final tableIds = content.tables.expand((t) => t.blockIds).toSet();
    final contentTitle = ChapterLayout.firstBlockIsChapterTitle(content, chapterTitle);
    if (!contentTitle && chapterTitle.trim().isNotEmpty) {
      final title = measurer.measureChapterTitle(chapterTitle);
      add(ScrollCell(ContentBlock(id: title.blockId, kind: BlockKind.heading,
        runs: title.runs), title, 0, 0, title.lines.length, 0));
    }
    for (final block in content.blocks) {
      if (tables[block.id] case final table?) {
        final measured = measureTable(table, byId, options);
        final total = tableHeight(measured);
        var from = 0.0;
        while (from < total - .1) {
          final to = tableCut(measured, from, options.contentHeight);
          final end = to > from ? to : math.min(total, from + measured.first.tableUnit);
          final gap = from == 0 ? options.paragraphGap : 0.0;
          final fragments = tableFragments(measured, from, end, gap);
          final first = fragments.firstWhere((f) => !f.frameOnly, orElse: () => fragments.first);
          add(ScrollCell(byId[first.block.blockId] ?? block, first.block, 0,
            first.lineFrom, first.lineTo, 0, table: fragments, tableHeight: end - from + gap));
          from = end;
        }
        await Future<void>.delayed(Duration.zero);
      }
      if (tableIds.contains(block.id)) continue;
      final text = blockTextOf(block);
      var offset = 0;
      var first = true;
      do {
        if (cancelled()) throw const ScrollPreparationCancelled();
        final end = snapToGrapheme(text, math.min(text.length, offset + 2048));
        final piece = text.length <= 2048
            ? block
            : ContentBlock(
                id: block.id,
                kind: block.kind,
                level: block.level,
                runs: _runsIn(block.runs, offset, end),
              );
        final measured = measurer.measure(
          piece,
          withIndent: first && options.settings.indent && block.kind == BlockKind.paragraph,
          asChapterTitle: contentTitle && block == content.blocks.first,
        );
        // 最后一行可能还没满，交给下一批与后续文字一起测量。
        final count =
            measured.lines.length -
            (end < text.length && measured.lines.length > 1 ? 1 : 0);
        if (!measured.isText) {
          add(ScrollCell(block, measured, 0, 0, 0, options.paragraphGap));
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
              first && line == 0 && (block != content.blocks.first || !contentTitle)
                  ? options.paragraphGap : 0,
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
      final gap = options.textScaler.scale(options.settings.fontSize.toDouble()) *
          options.settings.lineHeight * 2;
      cells.add(ScrollCell(last.block, last.measured, last.offset,
          last.from, last.to, last.gap, endGap: gap, table: last.table, tableHeight: last.tableHeight));
      height += gap;
    }
    return ScrollChapter(content, cells, starts, height);
  }

  Locator anchorAt(double y, LocatorMapper mapper) {
    final i = cellAt(y);
    final cell = cells[i];
    if (cell.table.isNotEmpty) {
      final parts = cell.table.where((f) => !f.frameOnly).toList();
      if (parts.isEmpty) return mapper.at(cell.block, 0);
      final fragment = parts.where((f) => f.y + f.height > y - starts[i]).firstOrNull ?? parts.last;
      final block = content.blocks.firstWhere((b) => b.id == fragment.block.blockId);
      return mapper.at(block, fragment.block.lines.isEmpty ? 0 : fragment.block.lines[fragment.lineFrom].start);
    }
    if (cell.measured.isDecoration) return mapper.chapterStart(content.blocks);
    if (!cell.measured.isText) {
      return mapper.at(cell.block, 0, affinity: LocatorAffinity.before);
    }
    var top = starts[i] + cell.gap;
    var line = cell.from;
    while (line + 1 < cell.to && top + cell.measured.lines[line].height <= y + 0.00001) {
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
    if (content.blocks.isNotEmpty && anchor.blockId == content.blocks.first.id &&
        anchor.utf16Offset == 0 && cells.first.measured.isTitleDecoration) {
      return 0;
    }
    for (var i = 0; i < cells.length; i++) {
      final cell = cells[i];
      if (cell.table.isNotEmpty) {
        for (final fragment in cell.table) {
          if (fragment.frameOnly || fragment.block.blockId != anchor.blockId) continue;
          final lines = fragment.block.lines;
          if (lines.isEmpty || (anchor.utf16Offset >= lines[fragment.lineFrom].start &&
              anchor.utf16Offset <= lines[fragment.lineTo - 1].end)) { return starts[i] + fragment.y; }
        }
        continue;
      }
      if (cell.block.id != anchor.blockId) continue;
      if (!cell.measured.isText) return starts[i];
      var top = starts[i] + cell.gap;
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
