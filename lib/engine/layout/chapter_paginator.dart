/// 分页器：把测量好的块按行填进页面（实现计划 4 / S5）。
///
/// 三条必须守住的口径：
/// 1. **只按行边界切分**。所有块的行范围首尾相接，因此把整章各页文本按顺序拼起来
///    必然等于标准化正文——这是「不漏字、不重复」的核心验收；
/// 2. **防孤悬**：标题不留页尾（标题 + 下一块首行同页），图片后紧跟标题时整组判定；
/// 3. **确定性**：同一份输入永远得到同一份分页结果，因此跳页、向后翻页都只要
///    从章首重放，不需要第二套回填算法（实现计划 5.4）。
library;

import 'dart:collection';
import 'dart:ui' show Offset, Rect, Size;
import 'dart:math' as math;

import '../../domain/models/book_document.dart';
import '../../domain/models/locator.dart';
import 'container_flow_sizing.dart';
import 'compact_image_policy.dart';
import 'parallel_flow_layout.dart';
import 'gallery_layout.dart';
import 'collapsed_table_borders.dart';
import 'block_flow_spacing.dart';
import 'block_measure.dart';
import 'vertical_margins.dart';
import 'measured_block.dart';
import 'table_layout.dart';
import 'parallel_flow_slices.dart';
import 'styled_table_pages.dart';

part 'page_slice.dart';
part 'container_page_geometry.dart';
part 'compact_illustration.dart';

/// 一页的构建过程（页内已用高度只在构建期可变）。
class _PageBuilder {
  _PageBuilder(this.paint);
  final bool paint;
  bool _empty = true;
  final List<PageFragment> fragments = [];
  final List<PageFragment> repeatedHeader = [];
  double usedHeight = 0;
  double flowBottom = 0;

  bool get isEmpty => _empty;
  bool get isNotEmpty => !_empty;

  void add(PageFragment fragment, {bool advanceFlow = true}) {
    if (paint) fragments.add(fragment);
    advance(fragment.y + fragment.height, advanceFlow: advanceFlow);
  }

  void advance(double bottom, {bool advanceFlow = true}) {
    _empty = false;
    usedHeight = math.max(usedHeight, bottom);
    // 下一块从当前块的末边出发。向上叠放时，最远绘制位置仍应留给整页。
    if (advanceFlow) flowBottom = bottom;
  }

  PageSlice build(int index, List<MeasuredBlock> pageImages) => PageSlice(
    index: index,
    paintFragments: repeatedHeader.isEmpty
        ? null
        : List.unmodifiable([
            ...repeatedHeader,
            ...fragments,
            for (final image in pageImages)
              PageFragment.whole(image, y: image.pageTop!),
          ]),
    fragments: List.unmodifiable([
      ...fragments,
      for (final image in pageImages)
        PageFragment.whole(image, y: image.pageTop!),
    ]),
    usedHeight: usedHeight,
    start: _startAnchor(
      fragments
              .where(
                (f) =>
                    !f.frameOnly &&
                    (!f.block.isDecoration || f.block.isTitleDecoration),
              )
              .firstOrNull ??
          _contentFallback(before: true),
    ),
    end: _endAnchor(
      fragments
              .where(
                (f) =>
                    !f.frameOnly &&
                    (!f.block.isDecoration || f.block.isTitleDecoration),
              )
              .lastOrNull ??
          _contentFallback(before: false),
    ),
  );

  /// 整页只有表格边框／盒子这类 `frameOnly` 片段时，页首尾位置仍要落在真实
  /// 单元格块上；不能用分页临时补的表格盒子（`isTableBox`）。
  PageFragment _contentFallback({required bool before}) {
    final candidates = fragments.where((f) => !f.block.isTableBox).toList();
    final usable = candidates.isEmpty ? fragments : candidates;
    return before ? usable.first : usable.last;
  }

  static PageAnchor _startAnchor(PageFragment fragment) {
    if (fragment.frameOnly || fragment.block.lines.isEmpty) {
      return PageAnchor(
        blockId: fragment.block.blockId,
        utf16Offset: 0,
        affinity: LocatorAffinity.before,
      );
    }
    return PageAnchor(
      blockId: fragment.block.blockId,
      utf16Offset: fragment.block.lines[fragment.lineFrom].start,
    );
  }

  static PageAnchor _endAnchor(PageFragment fragment) {
    if (fragment.frameOnly || fragment.block.lines.isEmpty) {
      return PageAnchor(
        blockId: fragment.block.blockId,
        utf16Offset: 0,
        affinity: LocatorAffinity.after,
      );
    }
    return PageAnchor(
      blockId: fragment.block.blockId,
      utf16Offset: fragment.block.lines[fragment.lineTo - 1].end,
    );
  }
}

/// 可按需准备的测量序列。has() 只准备所查询位置，不提前测完整章。
abstract interface class MeasuredBlockSource {
  bool has(int index);
  MeasuredBlock operator [](int index);
}

class _ListMeasuredBlocks implements MeasuredBlockSource {
  _ListMeasuredBlocks(this.values);
  final List<MeasuredBlock> values;
  @override
  bool has(int index) => index < values.length;
  @override
  MeasuredBlock operator [](int index) => values[index];
}

class ChapterPaginator {
  ChapterPaginator({
    required this.pageHeight,
    this.gapBefore,
    this.measurer,
    this.pageImages = const [],
    this.backgroundOnlyAnchor,
    this.containerSizing,
    this.chapterStarts = const {},
    this.compactIllustrations = true,
    this.parallelFlow,
  });

  final Set<String> chapterStarts;
  final bool compactIllustrations;
  final ParallelFlowLayout? parallelFlow;
  final double pageHeight;
  final BlockMeasurer? measurer;
  final List<MeasuredBlock> pageImages;
  final String? Function()? backgroundOnlyAnchor;
  final ContainerFlowSizing? Function()? containerSizing;

  /// 块之间的段距；为空时用固定值（测试与纯算术场景）
  final double Function(MeasuredBlock previous, MeasuredBlock current)?
  gapBefore;

  /// 浮点容差：行高是小数，累加后允许略微「超」一页，避免因为 1e-9 丢一行
  static const double _epsilon = 0.1;

  static const double _fallbackGap = 16;

  List<PageSlice> paginate(List<MeasuredBlock> blocks) =>
      steps(_ListMeasuredBlocks(blocks)).whereType<PageSlice>().toList();

  /// 每次只推进一个可继续步骤；null 表示已有进展但当前页尚未封口。
  /// 标题和图片组的后文依赖仍由原规则查询，只有 flush 的页可交付。
  Iterable<PageSlice?> steps(
    MeasuredBlockSource blocks, {
    int firstPage = 0,
    int firstBlock = 0,
    int firstLine = 0,
    void Function(int page, int block, int line)? onBoundary,
    void Function()? onPageSealed,
    void Function(int)? releaseBefore,
  }) {
    final pages = _steps(
      blocks,
      firstPage,
      firstBlock,
      firstLine,
      onBoundary,
      onPageSealed,
      releaseBefore,
    );
    return onPageSealed == null
        ? _positionBoxBackgrounds(pages, pageHeight)
        : pages;
  }

  Iterable<PageSlice?> _steps(
    MeasuredBlockSource blocks,
    int firstPage,
    int firstBlock,
    int firstLine,
    void Function(int page, int block, int line)? onBoundary,
    void Function()? onPageSealed,
    void Function(int)? releaseBefore,
  ) sync* {
    var pageCount = firstPage;
    var page = _PageBuilder(onPageSealed == null);
    var keepHeadingsThrough = -1;
    (int, int)? openingArtwork;
    final sizing = containerSizing?.call();
    var tails = const <ContainerFlowTail>[];
    MeasuredBlock? tailAnchor;
    double? chapterTopMargin;
    void placeTails() {
      for (final tail in tails) {
        // 和普通块的定高规则一样，分页只在正文所在页补留白。
        // 超出页底的纯空白没有可保存的原文位置。
        final extent = math.min(tail.height, pageHeight - page.flowBottom);
        if (extent <= 0) break;
        page.add(
          PageFragment.containerTail(
            tailAnchor!,
            tail,
            page.flowBottom,
            extent,
          ),
        );
      }
      tails = const [];
    }

    PageSlice? flush({int? block, int line = 0}) {
      final images = pageCount == 0 ? pageImages : const <MeasuredBlock>[];
      if (onPageSealed != null) {
        if (page.isNotEmpty || images.isNotEmpty) {
          pageCount++;
          onPageSealed();
          page = _PageBuilder(false);
        }
        return null;
      }
      if (page.isEmpty && images.isNotEmpty) {
        // 只有一张绝对定位图片的章也需要能够打开并定位。
        page.add(PageFragment.whole(images.first, y: images.first.pageTop!));
        return page.build(pageCount++, images.skip(1).toList());
      }
      if (page.isEmpty) return null;
      final result = page.build(pageCount++, images);
      page = _PageBuilder(onPageSealed == null);
      // 整页封口，且下一步位于普通块或段落续行时才可从空页重启。
      if (block != null &&
          onBoundary != null &&
          !_continuesBackground(result, pageHeight) &&
          (sizing?.canRestartAt(blocks[block].blockId, line) ?? true)) {
        onBoundary(pageCount, block, line);
      }
      return result;
    }

    /// 需要 [needed] 高度；当前页放不下就换页。
    /// 空页不再换（否则会死循环），返回空页时的实际可用高度由调用方兜底。
    PageSlice? ensure(double needed, int block) {
      if (page.isEmpty) return null;
      if (page.flowBottom + needed <= pageHeight + _epsilon) return null;
      return flush(block: block);
    }

    /// 续页页首不重复加段距。章首作者边距可伸入纸面的上方留白。
    double offsetIn(double gap) => page.isEmpty
        ? (pageCount == 0 ? chapterTopMargin! : 0.0)
        : page.flowBottom + gap;

    for (var i = firstBlock; blocks.has(i); i++) {
      releaseBefore?.call(i);
      placeTails();
      var block = blocks[i];
      if (block.isPageImage || block.collapsesThrough) continue;
      final forced = measurer?.displayTree?.pageBreaks[block.blockId];
      if ((forced?.contains(0) == true ||
              chapterStarts.contains(block.blockId)) &&
          !block.isDecoration &&
          page.isNotEmpty) {
        yield flush(block: i);
      }
      var flowStart = i;
      while (blocks[flowStart].positionedOverlay &&
          blocks.has(flowStart + 1) &&
          blocks[flowStart + 1].tableId == block.tableId) {
        flowStart++;
      }
      var gap = _gapBetween(blocks, flowStart);
      // 页尾纯装饰可以收短留白；避免为了空白把整个题花送到下一页页首。
      if (gap > 0 &&
          page.isNotEmpty &&
          page.flowBottom + gap + block.height > pageHeight &&
          block.height + page.flowBottom <= pageHeight &&
          block.lines.length == 1 &&
          block.containerBoxes.any((frame) => frame.lineTo == 1) &&
          measurer?.isClosingFloatOrnament(block) == true) {
        gap = pageHeight - block.height - page.flowBottom;
      }
      chapterTopMargin ??= gap;

      if (block.tableId != null) {
        var group = <MeasuredBlock>[block];
        while (blocks.has(i + 1) && blocks[i + 1].tableId == block.tableId) {
          group.add(blocks[++i]);
        }
        if (sizing != null && !block.isParallelFlow) {
          tails = sizing.add(group, gap: gap, height: tableHeight(group));
          tailAnchor = group.last;
        }
        if (block.isParallelFlow) {
          final natural = group;
          final fit = compactIllustrations && parallelFlow != null
              ? parallelFlow!.fitForPage(natural, measurer!, offsetIn(gap))
              : FloatPageFit(natural);
          group = fit.blocks;
          // 浮动插图在页尾放不下时，和旁边的首行一起移到续页，
          // 避免左边先显示诗句、右边的图到下一页才出现。
          final imageBottom = fit.leadingImageBottom;
          if (imageBottom > 0 &&
              (imageBottom <= pageHeight || fit.hasContinuableCaption)) {
            final before = pageCount;
            final previous = ensure(gap + imageBottom, i - group.length + 1);
            if (pageCount != before) {
              yield previous;
              // 若同排的另一张图仍装不下，移到新页后重新按新页余量试排。
              group = compactIllustrations && parallelFlow != null
                  ? parallelFlow!.fitForPage(natural, measurer!, 0).blocks
                  : natural;
            }
          }
          if (sizing != null) {
            tails = sizing.add(group, gap: gap, height: tableHeight(group));
            tailAnchor = group.last;
          }
          final flowPages = parallelFlowPages(group, offsetIn(gap), pageHeight);
          for (var p = 0; p < flowPages.length; p++) {
            if (p > 0) yield flush();
            final fragments = flowPages[p];
            if (fragments.isEmpty) continue;
            var bottom = double.negativeInfinity;
            for (final fragment in fragments) {
              page.add(fragment, advanceFlow: false);
              if (!fragment.block.positionedOverlay) {
                bottom = math.max(bottom, fragment.y + fragment.height);
              }
            }
            if (bottom.isFinite) page.flowBottom = bottom;
          }
          yield null;
          continue;
        }
        if (block.tableUnit == 0) {
          var current = 0;
          for (final slice in styledTablePages(
            group,
            offsetIn(gap),
            pageHeight,
          )) {
            if (slice.page > current) yield flush();
            current = slice.page;
            if (page.paint) page.repeatedHeader.addAll(slice.repeatedHeader);
            for (final fragment in slice.fragments) {
              page.add(fragment, advanceFlow: false);
            }
            page.flowBottom = slice.bottom;
            page.usedHeight = math.max(page.usedHeight, slice.bottom);
            yield null;
          }
          continue;
        }
        var from = 0.0;
        final height = tableHeight(group);
        while (from < height - _epsilon) {
          final y = offsetIn(from == 0 ? gap : 0);
          var to = tableCut(group, from, pageHeight - y);
          if (to <= from) {
            if (page.isNotEmpty) {
              yield flush();
              continue;
            }
            to = math.min(height, from + block.tableUnit);
          }
          for (final fragment in tableFragments(
            group,
            from,
            to,
            y,
            pageHeight: pageHeight,
          )) {
            page.add(fragment, advanceFlow: false);
          }
          page.flowBottom = y + to - from;
          from = to;
          if (from < height - _epsilon) yield flush();
          yield null;
        }
        continue;
      }

      // 片段 y 是所有绘制与定位消费者共同使用的原点。续页只补当前仍打开的 clone 盒。
      double contentOffset(int line) =>
          offsetIn(gap) +
          (page.isEmpty && pageCount > 0
              ? _cloneInsets(block, line, top: true)
              : 0);
      final after = _cloneInsets(
        block,
        math.max(0, block.lines.length - 1),
        top: false,
      );
      var imageTail = after;
      if (block.imageSize != null && block.pageTop == null) {
        imageTail = _imageTail(blocks, i, after);
        final available = pageHeight - contentOffset(0) - imageTail;
        if (page.isNotEmpty &&
            block.height > available &&
            _canCompactImage(blocks, i)) {
          block = _fitImageOnPage(block, available);
        }
      }
      if (sizing != null) {
        tails = sizing.add([block], gap: gap, height: block.height);
        tailAnchor = block;
      }
      if (block.pageTop != null && block.height <= pageHeight) {
        final target = math.max(contentOffset(0), block.pageTop!);
        if (target + block.height + after > pageHeight + _epsilon &&
            page.isNotEmpty) {
          yield flush(block: i);
        }
        page.add(
          PageFragment.whole(
            block,
            y: math.max(contentOffset(0), block.pageTop!),
          ),
        );
        yield null;
        continue;
      }
      if (block.lines.isEmpty) {
        yield ensure(gap + block.height + imageTail, i);
        page.add(PageFragment.whole(block, y: contentOffset(0)));
        if (block.kind == BlockKind.image &&
            chapterStarts.contains(block.blockId)) {
          openingArtwork = (pageCount, _nextFlowIndex(blocks, i));
        }
        yield null;
        continue;
      }

      final entry = measurer?.displayTree?.portraits[block.blockId];
      if (page.isNotEmpty &&
          entry?.name.id == block.blockId &&
          !(i == firstBlock && firstLine > 0) &&
          blocks.has(i + 2)) {
        final image = blocks[i + 1], bio = blocks[i + 2];
        if (image.imageSize != null &&
            image.blockId == entry!.portrait.id &&
            bio.blockId == entry.bio.id &&
            bio.lines.isNotEmpty) {
          final keep =
              block.height +
              _gapBetween(blocks, i + 1) +
              image.height +
              _gapBetween(blocks, i + 2) +
              biographyStartHeight(bio);
          if (keep <= pageHeight + _epsilon) yield ensure(gap + keep, i);
        }
      }
      if (block.kind == BlockKind.heading &&
          (forced == null || forced.every((o) => o == 0))) {
        // 图和标题是同一章的开头。放得下完整标题时，可以把正文首行留到右页。
        final followsOpeningArtwork = openingArtwork == (pageCount, i);
        if (compactIllustrations && !(i == firstBlock && firstLine > 0)) {
          if (i > keepHeadingsThrough) {
            final group = _headingGroup(blocks, i, contentOffset(0));
            if (group != null) {
              final keep =
                  !followsOpeningArtwork &&
                      group.minimum <=
                          pageHeight - _cloneInsets(block, 0, top: true)
                  ? group.minimum
                  : group.headings;
              yield ensure(gap + keep, i);
              keepHeadingsThrough = group.last;
            }
          }
          if (i <= keepHeadingsThrough &&
              contentOffset(0) + block.height + after <=
                  pageHeight + _epsilon) {
            page.add(PageFragment.whole(block, y: contentOffset(0)));
            yield null;
            continue;
          }
        }
        // 防孤悬：标题与下一块首行同页；标题本身高过一页时退化为按行切
        final keep =
            block.height +
            (followsOpeningArtwork ? 0 : _firstLineOfNext(blocks, i));
        if (keep <= pageHeight) {
          yield ensure(gap + keep + after, i);
          page.add(PageFragment.whole(block, y: contentOffset(0)));
          yield null;
          continue;
        }
      }

      // 文本块按行填充，可跨页
      var lineIndex = i == firstBlock ? firstLine : 0;
      while (lineIndex < block.lines.length) {
        final offset = contentOffset(lineIndex);
        final available = pageHeight - offset;
        var picked = _linesThatFit(block, lineIndex, available);
        if (forced != null) {
          for (var k = 1; k < picked; k++) {
            if (forced.contains(
              block.lines[lineIndex + k].start - block.displayPrefixLength,
            )) {
              picked = k;
              break;
            }
          }
        }
        if (picked == 0) {
          if (page.isEmpty) {
            // 单行都比一页高（超小窗口）：强制放一行，保证一定推进
            picked = 1;
          } else {
            yield flush(block: i, line: lineIndex);
            continue;
          }
        }
        var height = 0.0;
        for (var line = lineIndex; line < lineIndex + picked; line++) {
          height += block.lines[line].height;
        }
        // 块的第一片带顶部内边距与上边框，最后一片带底部内边距与下边框
        if (lineIndex == 0) height += block.bodyTop;
        if (lineIndex + picked >= block.lines.length) {
          height += block.bodyBottom;
        }
        if (page.paint) {
          page.add(
            PageFragment(
              block: block,
              lineFrom: lineIndex,
              lineTo: lineIndex + picked,
              y: offset,
              height: height,
            ),
          );
        } else {
          page.advance(offset + height);
        }
        lineIndex += picked;
        // 续页片段不带段距：gap 只在块的第一片上生效
        if (lineIndex < block.lines.length) {
          yield flush(block: i, line: lineIndex);
        }
        yield null;
      }
    }

    placeTails();
    if (page.isNotEmpty || (pageCount == 0 && pageImages.isNotEmpty)) {
      yield flush();
    } else if (pageCount == 0) {
      // 普通正文、空盒或定位图片已能生成页面时，背景直接画在已有页面上。
      final id = backgroundOnlyAnchor?.call();
      if (id != null) {
        if (onPageSealed != null) {
          onPageSealed();
          return;
        }
        final anchor = PageAnchor(blockId: id, utf16Offset: 0);
        yield PageSlice(
          index: 0,
          fragments: const [],
          usedHeight: pageHeight,
          start: anchor,
          end: anchor,
        );
      }
    }
  }

  /// 第 [index] 块之前的段距；页首的块不加（页首本来就靠边）
  double _gapBetween(MeasuredBlockSource blocks, int index) {
    var previous = index - 1;
    VerticalMargin? intervening;
    while (previous >= 0) {
      final block = blocks[previous];
      if (block.collapsesThrough) {
        final edges = block.leadingMargin.join(block.trailingMargin);
        intervening = intervening?.join(edges) ?? edges;
      } else if (!block.isPageImage && !block.positionedOverlay) {
        break;
      }
      previous--;
    }
    final current = blocks[index];
    if (previous < 0) {
      return resolveBlockGap(
        null,
        current,
        baseline: 0,
        intervening: intervening,
      );
    }
    final custom = gapBefore;
    final predecessor = blocks[previous];
    if (measurer case final flow?) {
      return flow.gapBefore(predecessor, current, intervening: intervening);
    }
    final baseline = custom?.call(predecessor, current) ?? _fallbackGap;
    return intervening == null
        ? baseline
        : resolveBlockGap(
            predecessor,
            current,
            baseline: baseline,
            intervening: intervening,
          );
  }

  /// 标题后的「下一块首行」高度（含段距），用于防孤悬判定。
  double _firstLineOfNext(MeasuredBlockSource blocks, int index) {
    final nextIndex = _nextFlowIndex(blocks, index);
    if (!blocks.has(nextIndex)) return 0;
    final next = blocks[nextIndex];
    if (_breaksBefore(next)) return 0;
    final nextGap = _gapBetween(blocks, nextIndex);
    if (next.lines.isNotEmpty) return nextGap + next.lines.first.height;
    // 图片不可拆，整块算上（图片块自己会做整组判定，这里只取一次高度）
    return nextGap + next.height;
  }

  /// 从 [from] 行开始，在 [available] 高度内最多能放几行。
  int _linesThatFit(MeasuredBlock block, int from, double available) {
    // 第一片要先把顶部内边距与上边框算进去
    var limit = available;
    if (from == 0) limit -= block.bodyTop;
    var used = 0.0;
    var count = 0;
    final cloned = block.hasClonedBox;
    for (var i = from; i < block.lines.length; i++) {
      final next = used + block.lines[i].height;
      final bottom = cloned
          ? _cloneInsets(block, i, top: false) +
                (i + 1 == block.lines.length ? block.bodyBottom : 0)
          : 0.0;
      if (next + bottom > limit + _epsilon) break;
      used = next;
      count++;
    }
    return count;
  }
}
