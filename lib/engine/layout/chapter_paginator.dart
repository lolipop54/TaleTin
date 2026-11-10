/// 分页器：把测量好的块按行填进页面（实现计划 4 / S5）。
///
/// 三条必须守住的口径：
/// 1. **只按行边界切分**。所有块的行范围首尾相接，因此把整章各页文本按顺序拼起来
///    必然等于标准化正文——这是「不漏字、不重复」的核心验收；
/// 2. **防孤悬**：标题不留页尾（标题 + 下一块首行同页），图片后紧跟标题时整组判定；
/// 3. **确定性**：同一份输入永远得到同一份分页结果，因此跳页、向后翻页都只要
///    从章首重放，不需要第二套回填算法（实现计划 5.4）。
library;

import 'dart:ui' show Offset, Rect, Size;
import 'dart:math' as math;

import '../../domain/models/book_document.dart';
import '../../domain/models/locator.dart';
import 'measured_block.dart';
import 'table_layout.dart';
import 'parallel_flow_slices.dart';

/// 页内一个片段：某个块在该页上的连续若干行（或整块图片/分隔线）。
class PageFragment {
  const PageFragment({
    required this.block,
    required this.lineFrom,
    required this.lineTo,
    required this.y,
    required this.height,
    this.tableFrame,
    this.frameOnly = false,
    this.tableTopEdge = true,
    this.tableBottomEdge = true,
  });

  /// 整块放入（图片、分隔线、标题）：
  /// 文本块的行范围就是它的全部行，图片与分隔线没有行。
  PageFragment.whole(MeasuredBlock block, {required double y})
    : this(
        block: block,
        lineFrom: 0,
        lineTo: block.lines.length,
        y: y,
        height: block.height,
      );

  final MeasuredBlock block;

  /// 行范围 [lineFrom, lineTo)；整块放入时两者都是 0
  final int lineFrom;
  final int lineTo;

  /// 页内顶部偏移
  final double y;

  /// 本片段占用的高度
  final double height;
  final Rect? tableFrame;
  final bool frameOnly;
  final bool tableTopEdge, tableBottomEdge;

  Size? get imageSize => block.imageSize;

  /// 页内图片的真实位置；横屏按高度缩小时仍位于容器中央。
  Rect? imageRectIn(double availableWidth) =>
      frameOnly ? null : block.imageRectIn(availableWidth, top: y);

  /// 页内一点落在哪张行内图片上；没有命中时返回 null。
  ///
  /// 坐标与绘制一致：片段顶部 + 行高 + 图片在行内的偏移。
  Iterable<({InlineImagePlacement image, Rect rect})>
  get positionedInlineImages sync* {
    if (frameOnly || block.lines.isEmpty) return;
    final width = block.layoutWidth;
    if (width == null) return;
    var top = y + block.textTopOf(lineFrom);
    for (var line = lineFrom; line < lineTo; line++) {
      final left = block.inset + block.horizontalOffset(line, width);
      for (final image in block.inlineImagesInLines(line, line + 1)) {
        yield (
          image: image,
          rect: Offset(left + image.left, top + image.top) & image.size,
        );
      }
      top += block.lines[line].height;
    }
  }

  InlineImagePlacement? inlineImageAt(Offset point) => positionedInlineImages
      .where((p) => p.rect.contains(point))
      .firstOrNull
      ?.image;

  /// 是否为跨页片段的后续部分（首行缩进只出现在 lineFrom == 0 的那一片）
  bool get isContinuation => block.lines.isNotEmpty && lineFrom > 0;

  @override
  String toString() =>
      'Fragment(${block.blockId}[$lineFrom,$lineTo)@$y,${height.toStringAsFixed(1)})';
}

/// 页首/页尾锚点：还没有摘录，摘录由上层（章节排版服务）补齐。
class PageAnchor {
  const PageAnchor({
    required this.blockId,
    required this.utf16Offset,
    this.affinity = LocatorAffinity.center,
  });

  final String blockId;
  final int utf16Offset;
  final LocatorAffinity affinity;
}

/// 一页的排版结果（不含章节信息，章节信息由上层附上）。
class PageSlice {
  const PageSlice({
    required this.index,
    required this.fragments,
    required this.usedHeight,
    required this.start,
    required this.end,
  });

  /// 章内页序，从 0 开始
  final int index;
  final List<PageFragment> fragments;
  final double usedHeight;

  /// 本页第一个字符与最后一个字符的位置
  final PageAnchor start;
  final PageAnchor end;
}

/// 一页的构建过程（页内已用高度只在构建期可变）。
class _PageBuilder {
  final List<PageFragment> fragments = [];
  double usedHeight = 0;

  bool get isEmpty => fragments.isEmpty;
  bool get isNotEmpty => fragments.isNotEmpty;

  void add(PageFragment fragment) {
    fragments.add(fragment);
    usedHeight = math.max(usedHeight, fragment.y + fragment.height);
  }

  PageSlice build(int index) => PageSlice(
    index: index,
    fragments: List.unmodifiable(fragments),
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
  ChapterPaginator({required this.pageHeight, this.gapBefore});

  final double pageHeight;

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
  }) sync* {
    var pageCount = firstPage;
    var page = _PageBuilder();

    PageSlice? flush({int? block, int line = 0}) {
      if (page.isEmpty) return null;
      final result = page.build(pageCount++);
      page = _PageBuilder();
      // 整页封口，且下一步位于普通块或段落续行时才可从空页重启。
      if (block != null) onBoundary?.call(pageCount, block, line);
      return result;
    }

    /// 需要 [needed] 高度；当前页放不下就换页。
    /// 空页不再换（否则会死循环），返回空页时的实际可用高度由调用方兜底。
    PageSlice? ensure(double needed, int block) {
      if (page.isEmpty) return null;
      if (page.usedHeight + needed <= pageHeight + _epsilon) return null;
      return flush(block: block);
    }

    /// 续页页首不加段距；章首保留作者的正上外边距。
    double offsetIn(double gap) => page.isEmpty
        ? (pageCount == 0 ? math.max(0, blocks[0].marginTop) : 0.0)
        : page.usedHeight + gap;

    for (var i = firstBlock; blocks.has(i); i++) {
      final block = blocks[i];
      final gap = _gapBetween(blocks, i);

      if (block.tableId != null) {
        final group = <MeasuredBlock>[block];
        while (blocks.has(i + 1) && blocks[i + 1].tableId == block.tableId) {
          group.add(blocks[++i]);
        }
        if (block.isParallelFlow) {
          final flowPages = parallelFlowPages(group, offsetIn(gap), pageHeight);
          for (var p = 0; p < flowPages.length; p++) {
            if (p > 0) yield flush();
            for (final fragment in flowPages[p]) {
              page.add(fragment);
            }
          }
          yield null;
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
            to = math.min(height, from + group.first.tableUnit);
          }
          for (final fragment in tableFragments(
            group,
            from,
            to,
            y,
            pageHeight: pageHeight,
          )) {
            page.add(fragment);
          }
          from = to;
          if (from < height - _epsilon) yield flush();
          yield null;
        }
        continue;
      }

      if (block.pageTop != null && block.height <= pageHeight) {
        final target = math.max(offsetIn(gap), block.pageTop!);
        if (target + block.height > pageHeight + _epsilon && page.isNotEmpty) {
          yield flush(block: i);
        }
        page.add(
          PageFragment.whole(block, y: math.max(offsetIn(gap), block.pageTop!)),
        );
        yield null;
        continue;
      }
      if (block.lines.isEmpty) {
        // 图片、分隔线、空块：整块放入
        // 图片属于它之前的内容。后面出现新标题不能反向绑定图片，
        // 否则连续插图会留下足以容纳下一张图的大块空白。
        yield ensure(gap + block.height, i);
        page.add(PageFragment.whole(block, y: offsetIn(gap)));
        yield null;
        continue;
      }

      if (block.kind == BlockKind.heading) {
        // 防孤悬：标题与下一块首行同页；标题本身高过一页时退化为按行切
        final keep = block.height + _firstLineOfNext(blocks, i, gap);
        if (keep <= pageHeight) {
          yield ensure(gap + keep, i);
          page.add(PageFragment.whole(block, y: offsetIn(gap)));
          yield null;
          continue;
        }
      }

      // 文本块按行填充，可跨页
      var lineIndex = i == firstBlock ? firstLine : 0;
      while (lineIndex < block.lines.length) {
        final offset = offsetIn(gap);
        final available = pageHeight - offset;
        var picked = _linesThatFit(block, lineIndex, available);
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
        page.add(
          PageFragment(
            block: block,
            lineFrom: lineIndex,
            lineTo: lineIndex + picked,
            y: offset,
            height: height,
          ),
        );
        lineIndex += picked;
        // 续页片段不带段距：gap 只在块的第一片上生效
        if (lineIndex < block.lines.length) {
          yield flush(block: i, line: lineIndex);
        }
        yield null;
      }
    }

    if (page.isNotEmpty) yield flush();
  }

  /// 第 [index] 块之前的段距；页首的块不加（页首本来就靠边）
  double _gapBetween(MeasuredBlockSource blocks, int index) {
    if (index <= 0) return 0;
    final custom = gapBefore;
    if (custom == null) return _fallbackGap;
    return custom(blocks[index - 1], blocks[index]);
  }

  /// 标题后的「下一块首行」高度（含段距），用于防孤悬判定。
  double _firstLineOfNext(MeasuredBlockSource blocks, int index, double gap) {
    if (!blocks.has(index + 1)) return 0;
    final next = blocks[index + 1];
    final nextGap = _gapBetween(blocks, index + 1);
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
    for (var i = from; i < block.lines.length; i++) {
      final next = used + block.lines[i].height;
      if (next > limit + _epsilon) break;
      used = next;
      count++;
    }
    return count;
  }
}
