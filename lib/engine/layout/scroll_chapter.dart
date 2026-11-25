import 'dart:math' as math;
import 'dart:ui' show Rect;

import '../../core/diagnostics/reader_turn_diagnostics.dart';
import '../../core/diagnostics/reader_work_trace.dart';
import '../../domain/models/book_document.dart';
import '../../domain/models/locator.dart';
import '../normalization/locator_mapper.dart';
import '../styles/chapter_styler.dart';
import '../styles/css_layout_styles.dart';
import 'block_measure.dart';
import 'block_measurement_cache.dart';
import 'book_background.dart';
import 'english_hyphenation.dart';
import 'layout_options.dart';
import 'measured_block.dart';
import 'measured_paragraphs.dart';
import 'chapter_layout.dart';
import 'chapter_paginator.dart';
import 'container_flow_sizing.dart';
import 'block_flow_spacing.dart';
import 'vertical_margins.dart';
import 'display_tree.dart';
import 'table_layout.dart';
import 'parallel_flow_layout.dart';

part 'scroll_cell.dart';

/// 只测量一个章节；超长段以小段测量并保留末行，下一批接着排，避免截断行。
class ScrollChapter {
  ScrollChapter(
    this.content,
    this.cells,
    this.starts,
    this.height, {
    this.options,
    this.paperImageHeight,
  });
  final LayoutOptions? options;
  final double? paperImageHeight;
  bool get fullWidthPaper => paperImageHeight != null;
  late final BlockBox? paperBox = options == null
      ? null
      : fullWidthPaper
          ? resolveFullWidthPaper(content, options!)
          : chapterBackground(content, options!);
  late final _viewportLayout = options == null
      ? null
      : '${options!.readingGeometrySignature}|${options!.publicationFonts.identity}';

  String _viewportKey(double y) {
    final index = cellAt(y), cell = cells[index];
    // 换版后即使旧分页缓存全部作废，只要重新测出的可见单元位置和尺寸一致，
    // 仍可恢复图内的原处。浮动框或前文实际改变时才回到原文字位。
    return '$_viewportLayout|${cell.block.id}|${starts[index]}|${cell.height}|${cell.textTop}';
  }

  Locator withViewport(Locator point, double y) {
    if (_viewportLayout == null || cells.isEmpty) return point;
    return point.copyWith(scrollViewport: (layout: _viewportKey(y), y: y));
  }

  /// 一张高图或段间空白可以占半屏，单靠块号和字位只能回到其上沿。
  /// 用原文再核对一次，同一排版且仍是这个落点才重用格内的像素位置。
  double viewportOffsetOf(Locator point) {
    final saved = point.scrollViewport;
    if (saved != null &&
        _viewportLayout != null &&
        cells.isNotEmpty &&
        saved.y >= 0 &&
        saved.y <= height &&
        saved.layout == _viewportKey(saved.y)) {
      final mapper = LocatorMapper(
        bookId: point.bookId,
        contentVersion: point.contentVersion,
        chapterId: content.chapterId,
      );
      if (anchorAt(saved.y, mapper, landing: point).samePosition(point)) {
        return saved.y;
      }
    }
    return offsetOf(point);
  }
  final ChapterContent content;
  final List<ScrollCell> cells;
  final List<double> starts;
  final double height;

  static Future<ScrollChapter> prepare(
    ChapterContent content,
    LayoutOptions options, {
    required bool Function() cancelled,
    String chapterTitle = '',
    bool chapterStart = true,
    bool chapterEnd = true,
    BlockMeasurementCache? measurementCache,
    MeasuredParagraphs? paragraphs,
    Future<double?> Function(String path, double width)? preparePaperHeight,
  }) async {
    final cells = <ScrollCell>[];
    final starts = <double>[];
    final setup = ReaderWorkTrace.start('scroll.chapterSetup');
    content = CssLayoutStyles.resolve(content, options);
    setup?.mark('styles');
    await EnglishHyphenation.prepare();
    final measurer = BlockMeasurer(
      options,
      paginated: false,
      styleTable: ChapterStyler.layoutTableOf(content),
      displayTree: DisplayTree.build(content),
      cache: measurementCache,
      paragraphs: paragraphs,
    );
    setup?.mark('displayTree');
    var height = 0.0;
    await measurer.prepareMath(content);
    setup?.finish();
    final pageImages = measurer.pageImagesOf(content);
    final pageImageIds = pageImages.map((b) => b.blockId).toSet();
    final sizing = ContainerFlowSizing.build(
      measurer.displayTree!,
      ChapterStyler.layoutTableOf(content),
      options,
    );
    MeasuredBlock? previous;
    VerticalMargin? intervening;
    var carriedOverlap = 0.0;
    double gapFor(MeasuredBlock block, double initial) {
      final before = previous;
      final gap = before == null
          ? resolveBlockGap(
              null,
              block,
              baseline: initial,
              intervening: intervening,
            )
          : measurer.gapBefore(before, block, intervening: intervening);
      final placement = gap + carriedOverlap;
      return block.pageTop == null
          ? placement
          : math.max(placement, block.pageTop! - height);
    }

    void add(ScrollCell cell) {
      starts.add(height);
      cells.add(cell);
      height += cell.height;
      // 列表项不能取负高度。尚未消化的向上位移传给下一个绘制单元。
      carriedOverlap = math.min(0, cell.flowExtent);
      if (!cell.containerTail) {
        previous = cell.measured;
        intervening = null;
      }
    }

    void addTails(
      ContentBlock anchor,
      MeasuredBlock measured,
      List<ContainerFlowTail>? tails,
    ) {
      if (tails == null) return;
      for (final tail in tails) {
        final fragment = PageFragment.containerTail(
          measured,
          tail,
          carriedOverlap,
          tail.height,
        );
        add(
          ScrollCell(
            anchor,
            fragment.block,
            0,
            0,
            0,
            0,
            table: [fragment],
            tableHeight: tail.height + carriedOverlap,
            containerTail: true,
          ),
        );
      }
    }

    void addDecoration(ContentBlock anchor, MeasuredBlock empty) {
      if (empty.collapsesThrough) {
        final edges = empty.leadingMargin.join(empty.trailingMargin);
        intervening = intervening?.join(edges) ?? edges;
        return;
      }
      final carry = carriedOverlap;
      final gap = empty.flowMargins == null ? carry : gapFor(empty, 0);
      add(ScrollCell(anchor, empty, 0, 0, 0, gap));
      addTails(
        anchor,
        empty,
        sizing?.add([empty], gap: gap - carry, height: empty.height),
      );
    }

    void addDecorations(ContentBlock anchor, int index) {
      final items = measurer.measureBefore(index);
      for (var i = 0; i < items.length; i++) {
        final first = items[i];
        if (first.tableId == null) {
          addDecoration(anchor, first);
          continue;
        }
        final group = [first];
        while (i + 1 < items.length && items[i + 1].tableId == first.tableId) {
          group.add(items[++i]);
        }
        final total = tableHeight(group);
        final firstGap = gapFor(first, 0);
        var from = 0.0;
        for (final end in styledTableScrollCuts(
          group,
          total,
          options.contentHeight,
        )) {
          final gap = from == 0 ? firstGap : 0.0;
          final fragments = tableFragments(group, from, end, gap);
          add(
            ScrollCell(
              anchor,
              first,
              0,
              0,
              0,
              0,
              table: fragments,
              tableHeight: end - from + gap,
            ),
          );
          from = end;
        }
      }
    }

    final work = Stopwatch()..start();
    final byId = {for (final block in content.blocks) block.id: block};
    final tables = {
      for (final table in content.tables) table.blockIds.first: table,
    };
    final tableIds = {
      ...content.tables.expand((t) => t.blockIds),
      ...measurer.displayTree!.captionBlockIds,
    };
    final parallel = ParallelFlowLayout(
      content,
      measurer.displayTree!,
      ChapterStyler.layoutTableOf(content),
      options,
    );
    // 章题和短横线只给 TXT 补；其他格式按原书内容排，不插入标题。
    final contentTitle =
        chapterStart &&
        options.insertChapterTitle &&
        ChapterLayout.firstBlockIsChapterTitle(content, chapterTitle);
    if (chapterStart &&
        options.insertChapterTitle &&
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
      addDecorations(block, blockIndex);
      if (measurer.displayTree!.hiddenBlocks.contains(blockIndex) &&
          !tables.containsKey(block.id)) {
        continue;
      }
      if (pageImageIds.contains(block.id) ||
          parallel.members.contains(blockIndex)) {
        continue;
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
        if (measured.isEmpty) continue;
        final total = tableHeight(measured);
        final carry = carriedOverlap;
        final firstGap = gapFor(
          measured.firstWhere((b) => !b.positionedOverlay),
          options.paragraphGap,
        );
        final styledCuts =
            measured.first.tableUnit == 0 && !measured.first.isParallelFlow
            ? styledTableScrollCuts(
                measured,
                total,
                options.contentHeight,
              ).iterator
            : null;
        var from = 0.0;
        while (from < total - .1) {
          final to = styledCuts?.moveNext() == true
              ? styledCuts!.current
              : measured.first.isParallelFlow
              ? total
              : tableCut(measured, from, options.contentHeight);
          final end = to > from
              ? to
              : math.min(total, from + measured.first.tableUnit);
          final gap = from == 0 ? firstGap : carriedOverlap;
          final fragments = tableFragments(measured, from, end, gap);
          if (fragments.isEmpty) {
            from = end;
            continue;
          }
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
        if (measured.any((b) => b.positionedOverlay)) {
          previous = measured.lastWhere((b) => !b.positionedOverlay);
        }
        addTails(
          byId[measured.last.blockId] ?? block,
          measured.last,
          sizing?.add(measured, gap: firstGap - carry, height: total),
        );
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
            : measurer.inlineSafeEnd(
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
                    if (image.offset >= offset &&
                        (image.offset < end || end == text.length))
                      image.positioned(image.offset - offset),
                ],
              );
        final trace = ReaderTurnDiagnostics.active;
        final clock = trace == null ? null : (Stopwatch()..start());
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
        if (clock != null && clock.elapsedMicroseconds >= 2000) {
          trace!.event('scroll.measureBlock', [
            clock.elapsedMicroseconds, end - offset, measured.lines.length,
          ]);
        }
        if (measured.boxId != null && measured.box != null) {
          int? containerOf(ContentBlock value) =>
              value.parentBox?.id ?? value.boxId;
          measured = measured.asBoxPart(
            first:
                first &&
                (blockIndex == 0 ||
                    containerOf(content.blocks[blockIndex - 1]) != measured.boxId),
            last:
                end == text.length &&
                (blockIndex + 1 == content.blocks.length ||
                    containerOf(content.blocks[blockIndex + 1]) != measured.boxId),
          );
        }
        // 最后一行可能还没满，交给下一批与后续文字一起测量。
        final count =
            measured.lines.length -
            (end < text.length && measured.lines.length > 1 ? 1 : 0);
        final carry = carriedOverlap;
        final blockGap =
            first && (block != content.blocks.first || !contentTitle)
            ? gapFor(measured, options.paragraphGap)
            : carry;
        if (!measured.isText) {
          final gap = gapFor(measured, options.paragraphGap);
          add(ScrollCell(block, measured, 0, 0, 0, gap));
          addTails(
            block,
            measured,
            sizing?.add([measured], gap: gap - carry, height: measured.height),
          );
          break;
        }
        var flowed = 0.0;
        for (var line = 0; line < count; line += 12) {
          final cell = ScrollCell(
            block,
            measured,
            offset,
            line,
            math.min(count, line + 12),
            line == 0 ? blockGap : carriedOverlap,
          );
          flowed += cell.paintHeight;
          add(cell);
        }
        final nextOffset =
            offset +
            measured.lines[count - 1].end -
            measured.displayPrefixLength;
        addTails(
          block,
          measured,
          sizing?.add(
            [measured],
            gap: blockGap - carry,
            height: flowed,
            firstSlice: first,
            lastSlice: nextOffset >= text.length,
          ),
        );
        offset = nextOffset;
        first = false;
        // 给触摸和绘制让出执行机会，不一次排完整个长章。
        if (work.elapsedMicroseconds >= 3000) {
          await Future<void>.delayed(Duration.zero);
          work.reset();
        }
      } while (offset < text.length);
    }
    // 连续滚动会分格绘制，同一张定位图片可穿过格边界。相邻格共用
    // 图片的章内坐标和资源，不在正文序列重复插块。
    final overlays = <({MeasuredBlock block, double top, int cell})>[
      for (final b in pageImages) (block: b, top: b.pageTop!, cell: -1),
      for (final (i, c) in cells.indexed)
        for (final f in c.table)
          if (f.block.positionedOverlay &&
              (f.y < 0 || f.y + f.height > c.height))
            (block: f.block, top: starts[i] + f.y, cell: i),
    ];
    final imageBottom = overlays.fold(
      0.0,
      (max, image) => math.max(max, image.top + image.block.height),
    );
    if (imageBottom > height) {
      // 图超出正文底部时保留可滚到的区域，但不插进正文的段落与段距。
      final spacer = MeasuredBlock(
        blockId: overlays.last.block.blockId,
        kind: BlockKind.image,
        height: imageBottom - height,
        isDecoration: true,
      );
      add(ScrollCell(byId[spacer.blockId]!, spacer, 0, 0, 0, 0));
    }
    // 章尾只留两行正文高度；留白不另造正文块，已有位置和笔记仍指向原文。
    if (chapterEnd && cells.isNotEmpty) {
      final last = cells.removeLast();
      final gap =
          options.textScaler.scale(options.settings.fontSize.toDouble()) *
          options.settings.lineHeight *
          2;
      final tail = last.withEndGap(gap);
      cells.add(tail);
      height += tail.height - last.height;
    }
    // 纯装饰章节也有纸面高度。沿用空章锚点，不向持久正文插入占位块。
    addDecorations(
      content.blocks.lastOrNull ??
          ContentBlock(id: '', kind: BlockKind.paragraph),
      content.blocks.length,
    );
    final paper = chapterStart && chapterEnd && preparePaperHeight != null
        ? fullPageBackground(content)
        : null;
    final artHeight = paper == null ? null
        : await preparePaperHeight!(paper.imageUrl!, options.contentWidth);
    if (cancelled()) throw const ScrollPreparationCancelled();
    if (cells.isEmpty && chapterStart && chapterEnd) {
      final id = backgroundOnlyPageAnchor(content);
      if (id != null) {
        final anchor =
            content.blocks.firstOrNull ??
            ContentBlock(id: id, kind: BlockKind.paragraph);
        addDecoration(
          anchor,
          MeasuredBlock(
            blockId: id,
            kind: BlockKind.paragraph,
            isDecoration: true,
            height: artHeight ?? options.contentHeight,
          ),
        );
      }
    }
    for (var i = 0; i < cells.length && starts[i] < imageBottom; i++) {
      final start = starts[i], end = start + cells[i].height - cells[i].endGap;
      if (end <= start) continue;
      for (final image in overlays) {
        final top = image.top;
        if (i != image.cell && top < end && top + image.block.height > start) {
          cells[i].pageImages.add(
            PageFragment.whole(image.block, y: top - start),
          );
        }
      }
    }
    if (artHeight != null && cells.isNotEmpty) {
      // fullPageBackground 只接受不平铺的原书插画，正文超出画幅时直接接着排。
      final body = height - cells.last.endGap;
      final extent = math.max(body, artHeight);
      cells.last = cells.last.withEndGap(extent - body);
      height = extent;
    }
    return ScrollChapter(
      content, cells, starts, height,
      options: options, paperImageHeight: artHeight,
    );
  }

  Locator anchorAt(double y, LocatorMapper mapper, {Locator? landing}) {
    final i = cellAt(y);
    final cell = cells[i];
    if (cell.containerTail) {
      return mapper.at(cell.block, blockTextOf(cell.block).length);
    }
    if (cell.table.isNotEmpty) {
      final local = y - starts[i];
      // 两列可以同高。书签指到右格中间时，只有真正落在其行首才回报原偏移。
      if (landing != null &&
          landing.chapterId == mapper.chapterId &&
          cell.table.any(
            (f) =>
                !f.frameOnly &&
                !f.block.isDecoration &&
                f.block.blockId == landing.blockId &&
                (f.y - local).abs() < .00001 &&
                f.containsSourceOffset(landing.utf16Offset),
          )) {
        return landing;
      }
      final fragment = tableAnchorAt(cell.table, local);
      if (fragment == null) return mapper.at(cell.block, 0);
      final block = content.blocks.firstWhere(
        (b) => b.id == fragment.block.blockId,
      );
      return mapper.at(block, fragment.sourceStart);
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
    // 跳到行中某个字与跳到该行开头的屏幕高度相同。仅在原落点保留
    // 书签字位，读者开始滚动后继续按当前可见行记录进度。
    final start = cell.offsetAt(line);
    final end = cell.offset + cell.measured.lines[line].end -
        cell.measured.displayPrefixLength;
    if (landing != null &&
        landing.chapterId == mapper.chapterId &&
        landing.blockId == cell.block.id &&
        (top - y).abs() < .00001 &&
        landing.utf16Offset >= start &&
        (landing.utf16Offset < end ||
            (landing.utf16Offset == end && end == cell.block.runLength))) {
      return landing;
    }
    return mapper.at(
      cell.block,
      start.clamp(0, blockTextOf(cell.block).length),
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
        cells.firstOrNull?.measured.isTitleDecoration == true) {
      return 0;
    }
    double? decorationTop;
    for (var i = 0; i < cells.length; i++) {
      final cell = cells[i];
      for (final image in cell.pageImages) {
        if (image.block.blockId == anchor.blockId) {
          return starts[i] + image.y;
        }
      }
      if (cell.table.isNotEmpty) {
        for (final fragment in cell.table) {
          if (fragment.frameOnly || fragment.block.blockId != anchor.blockId) {
            continue;
          }
          if (fragment.containsSourceOffset(anchor.utf16Offset)) {
            return starts[i] + fragment.y;
          }
        }
        continue;
      }
      // 装饰留白借用相邻正文的块号，恢复正文位置时继续找真正绘制它的单元。
      if (cell.block.id != anchor.blockId) continue;
      if (cell.measured.isDecoration) {
        decorationTop ??= starts[i];
        continue;
      }
      if (!cell.measured.isText) return starts[i];
      var top = starts[i] + cell.textTop;
      for (var line = cell.from; line < cell.to; line++) {
        final end =
            cell.offset +
            cell.measured.lines[line].end -
            cell.measured.displayPrefixLength;
        // 折行边界属于下一行，整个原文段落的结束位置仍属于它的最后一行。
        if (anchor.utf16Offset < end ||
            (anchor.utf16Offset == end && end == cell.block.runLength)) {
          return top;
        }
        top += cell.measured.lines[line].height;
      }
    }
    // 纯背景封面只有装饰单元；它本身就是章首的可见位置。
    if (decorationTop != null) return decorationTop;
    final tree = _locatorDisplayTree ??= DisplayTree.build(content);
    final visible = tree.visibleIndexForHidden(anchor.blockId);
    if (visible != null) {
      return offsetOf(
        Locator(
          bookId: anchor.bookId,
          contentVersion: anchor.contentVersion,
          chapterId: anchor.chapterId,
          blockId: content.blocks[visible].id,
          utf16Offset: 0,
        ),
      );
    }
    return height;
  }

  DisplayTree? _locatorDisplayTree;

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
