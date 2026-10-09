/// 分页器：把测量好的块按行填进页面（实现计划 4 / S5）。
///
/// 三条必须守住的口径：
/// 1. **只按行边界切分**。所有块的行范围首尾相接，因此把整章各页文本按顺序拼起来
///    必然等于标准化正文——这是「不漏字、不重复」的核心验收；
/// 2. **防孤悬**：标题不留页尾（标题 + 下一块首行同页），图片后紧跟标题时整组判定；
/// 3. **确定性**：同一份输入永远得到同一份分页结果，因此跳页、向后翻页都只要
///    从章首重放，不需要第二套回填算法（实现计划 5.4）。
library;

import 'dart:ui' show Size;
import 'dart:ui' show Rect;
import 'dart:math' as math;

import '../../domain/models/book_document.dart';
import '../../domain/models/locator.dart';
import 'measured_block.dart';
import 'table_layout.dart';

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

  Size? get imageSize => block.imageSize;

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
        start: _startAnchor(fragments.where((f) => !f.frameOnly).firstOrNull ?? fragments.first),
        end: _endAnchor(fragments.where((f) => !f.frameOnly).lastOrNull ?? fragments.last),
      );

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

class ChapterPaginator {
  ChapterPaginator({required this.pageHeight, this.gapBefore});

  final double pageHeight;

  /// 块之间的段距；为空时用固定值（测试与纯算术场景）
  final double Function(MeasuredBlock previous, MeasuredBlock current)? gapBefore;

  /// 浮点容差：行高是小数，累加后允许略微「超」一页，避免因为 1e-9 丢一行
  static const double _epsilon = 0.1;

  static const double _fallbackGap = 16;

  List<PageSlice> paginate(List<MeasuredBlock> blocks) {
    final pages = <PageSlice>[];
    var page = _PageBuilder();

    void flush() {
      if (page.isEmpty) return;
      pages.add(page.build(pages.length));
      page = _PageBuilder();
    }

    /// 需要 [needed] 高度；当前页放不下就换页。
    /// 空页不再换（否则会死循环），返回空页时的实际可用高度由调用方兜底。
    void ensure(double needed) {
      if (page.isEmpty) return;
      if (page.usedHeight + needed <= pageHeight + _epsilon) return;
      flush();
    }

    /// 块在页内的顶部偏移：页首不加段距
    double offsetIn(double gap) =>
        page.isEmpty ? 0.0 : page.usedHeight + gap;

    for (var i = 0; i < blocks.length; i++) {
      final block = blocks[i];
      final gap = _gapBetween(blocks, i);

      if (block.tableId != null) {
        final group = <MeasuredBlock>[block];
        while (i + 1 < blocks.length && blocks[i + 1].tableId == block.tableId) {
          group.add(blocks[++i]);
        }
        var from = 0.0;
        final height = tableHeight(group);
        while (from < height - _epsilon) {
          final y = offsetIn(from == 0 ? gap : 0);
          var to = tableCut(group, from, pageHeight - y);
          if (to <= from) {
            if (page.isNotEmpty) { flush(); continue; }
            to = math.min(height, from + group.first.tableUnit);
          }
          for (final fragment in tableFragments(group, from, to, y)) { page.add(fragment); }
          from = to;
          if (from < height - _epsilon) flush();
        }
        continue;
      }

      if (block.lines.isEmpty) {
        // 图片、分隔线、空块：整块放入
        final group = block.kind == BlockKind.image
            ? _imageGroupHeight(blocks, i, gap)
            : block.height;
        ensure(gap + group);
        page.add(PageFragment.whole(block, y: offsetIn(gap)));
        continue;
      }

      if (block.kind == BlockKind.heading) {
        // 防孤悬：标题与下一块首行同页；标题本身高过一页时退化为按行切
        final keep = block.height + _firstLineOfNext(blocks, i, gap);
        if (keep <= pageHeight) {
          ensure(gap + keep);
          page.add(PageFragment.whole(block, y: offsetIn(gap)));
          continue;
        }
      }

      // 文本块按行填充，可跨页
      var lineIndex = 0;
      while (lineIndex < block.lines.length) {
        final offset = offsetIn(gap);
        final available = pageHeight - offset;
        var picked = _linesThatFit(block, lineIndex, available);
        if (picked == 0) {
          if (page.isEmpty) {
            // 单行都比一页高（超小窗口）：强制放一行，保证一定推进
            picked = 1;
          } else {
            flush();
            continue;
          }
        }
        var height = 0.0;
        for (var line = lineIndex; line < lineIndex + picked; line++) {
          height += block.lines[line].height;
        }
        page.add(PageFragment(
          block: block,
          lineFrom: lineIndex,
          lineTo: lineIndex + picked,
          y: offset,
          height: height,
        ));
        lineIndex += picked;
        // 续页片段不带段距：gap 只在块的第一片上生效
        if (lineIndex < block.lines.length) flush();
      }
    }

    if (page.isNotEmpty) pages.add(page.build(pages.length));
    return pages;
  }

  /// 第 [index] 块之前的段距；页首的块不加（页首本来就靠边）
  double _gapBetween(List<MeasuredBlock> blocks, int index) {
    if (index <= 0) return 0;
    final custom = gapBefore;
    if (custom == null) return _fallbackGap;
    return custom(blocks[index - 1], blocks[index]);
  }

  /// 「图片 + 段距 + 标题」整组高度；标题再带上自己的下一块首行。
  double _imageGroupHeight(List<MeasuredBlock> blocks, int index, double gap) {
    final block = blocks[index];
    if (index + 1 >= blocks.length) return block.height;
    final next = blocks[index + 1];
    if (next.kind != BlockKind.heading) return block.height;
    final nextGap = _gapBetween(blocks, index + 1);
    return block.height +
        nextGap +
        next.height +
        _firstLineOfNext(blocks, index + 1, gap);
  }

  /// 标题后的「下一块首行」高度（含段距），用于防孤悬判定。
  double _firstLineOfNext(
    List<MeasuredBlock> blocks,
    int index,
    double gap,
  ) {
    if (index + 1 >= blocks.length) return 0;
    final next = blocks[index + 1];
    final nextGap = _gapBetween(blocks, index + 1);
    if (next.lines.isNotEmpty) return nextGap + next.lines.first.height;
    // 图片不可拆，整块算上（图片块自己会做整组判定，这里只取一次高度）
    return nextGap + next.height;
  }

  /// 从 [from] 行开始，在 [available] 高度内最多能放几行。
  int _linesThatFit(MeasuredBlock block, int from, double available) {
    var used = 0.0;
    var count = 0;
    for (var i = from; i < block.lines.length; i++) {
      final next = used + block.lines[i].height;
      if (next > available + _epsilon) break;
      used = next;
      count++;
    }
    return count;
  }
}
