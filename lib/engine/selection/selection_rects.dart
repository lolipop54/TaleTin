/// 选区矩形与命中测试（实现计划 S15 / S1）。
///
/// 给定两个 Locator（选区两端）算出一页里每行的高亮矩形，把内容盒里的一点
/// 换算成**真实字符位置**，以及长按起选时给出所在整句。不做笔记 UI、不做跨章选区。
///
/// 坐标口径：矩形都在**页内容盒**坐标系里（左上角为原点），与
/// `PageCanvas` 的绘制坐标一致——正文盒子在屏幕上居中，命中测试前
/// 调用方要先减掉盒子原点。
///
/// 行内落点用与绘制同一个 [TextPainter]（同样的字号、字距与缩放）反查字符，
/// 不再按字符数等比估算：估算在半角、标点、两端对齐的行上会偏出好一个字。
library;

import 'dart:math' as math;
import 'package:flutter/painting.dart' show TextPainter, TextPosition, TextSelection;

import 'dart:ui' show Offset, Rect;

import '../../domain/models/book_document.dart';
import '../../domain/models/locator.dart';
import '../layout/chapter_layout.dart';
import '../layout/measured_block.dart';
import '../normalization/locator_mapper.dart';
import '../normalization/sentence_splitter.dart';
import 'selection_range.dart';

/// 一页里 [from, to] 选区的高亮矩形（页内容盒坐标）。
///
/// 跨章选区也能画：按章节顺序把范围裁到本章（首章取到章末、末章从章首起、
/// 中间章整章），再按本章内的两端算矩形。[chapterOrdinals] 缺失时只处理本章内的选区。
List<Rect> selectionRectsForPage({
  required ChapterLayout layout,
  required int pageIndex,
  required Locator from,
  required Locator to,
  Map<String, int>? chapterOrdinals,
}) {
  final clipped = clipRangeToChapter(
    layout: layout,
    from: from,
    to: to,
    chapterOrdinals: chapterOrdinals,
  );
  if (clipped == null) return const [];
  final orderedPair = clipped;
  final page = layout.page(pageIndex);
  if (page == null) return const [];

  final lower = _keyOf(layout, orderedPair.$1);
  final upper = _keyOf(layout, orderedPair.$2);
  if (lower == null || upper == null) return const [];
  // 调用方可能反着传，统一成阅读顺序
  final ordered = _isBefore(lower, upper);
  final startKey = ordered ? lower : upper;
  final endKey = ordered ? upper : lower;

  final rects = <Rect>[];
  for (final fragment in page.fragments) {
    if (fragment.frameOnly) continue;
    final block = fragment.block;
    if (block.lines.isEmpty) continue;
    final blockIndex = layout.blocks.indexOf(block);
    if (blockIndex < 0) continue;
    // 该块在选区内的偏移区间（显示文本坐标：含首行缩进前缀）
    final blockLength = block.text.length;
    final selectFrom = blockIndex > startKey.blockIndex
        ? -1
        : (blockIndex < startKey.blockIndex
            ? blockLength + 1
            : startKey.offset + block.displayPrefixLength);
    final selectTo = blockIndex < endKey.blockIndex
        ? blockLength + 1
        : (blockIndex > endKey.blockIndex
            ? -1
            : endKey.offset + block.displayPrefixLength);
    // 段前缩进（画出来的全角空格前缀）不算高亮：多段选取时后面每一段的首行
    // 也要从正文第一个字起画，否则看起来就是把段前空格也选上了（真机反馈）
    final blockFrom = math.max(selectFrom, block.displayPrefixLength);

    var y = fragment.y;
    for (var i = fragment.lineFrom; i < fragment.lineTo; i++) {
      final line = block.lines[i];
      final a = math.max(line.start, blockFrom);
      final b = math.min(line.end, selectTo);
      if (b > a) {
        // 高亮矩形按**真实字形位置**取：用与绘制同一个 TextPainter 问它这几个字
        // 落在哪几段横坐标上。按「本行字符数等比换算」算出来的框在中文避头尾、
        // 标点、两端对齐字距拉开时都会和文字对不齐（真机反馈过）。
        final painter = _linePainter(layout, block, i);
        final boxes = painter.getBoxesForSelection(
          TextSelection(
            baseOffset: a - line.start,
            // 行尾连字符一起高亮，但不加入原文范围或笔记摘录。
            extentOffset: b - line.start + (line.hyphenated && b == line.end ? 1 : 0),
          ),
        );
        painter.dispose();
        for (final box in boxes) {
          final left = block.inset + box.left;
          final width = box.right - box.left;
          if (width <= 0) continue;
          rects.add(Rect.fromLTWH(left, y, width, line.height));
        }
      }
      y += line.height;
    }
  }
  return rects;
}

/// 内容盒里的一点 → 最近的文本位置（长按与拖动定位用）。
///
/// 点在图片、空白或页外时返回 null。
Locator? locatorAtPointInPage({
  required ChapterLayout layout,
  required int pageIndex,
  required Offset position,
}) {
  final hit = _hitTest(layout: layout, pageIndex: pageIndex, position: position);
  if (hit == null) return null;
  return _locatorOf(layout, hit.blockId, hit.offset);
}

/// 长按起选：这一点所在的**整句**（用听书那套句读切分）。
///
/// 按句起选比按行起选更接近用户想选的东西，也不会一点就选中整行；
/// 之后靠手柄逐字调整（S1b）或拖动延伸。句子在块内，不跨块。
({Locator start, Locator end})? sentenceRangeAtPointInPage({
  required ChapterLayout layout,
  required int pageIndex,
  required Offset position,
}) {
  final hit = _hitTest(layout: layout, pageIndex: pageIndex, position: position);
  if (hit == null) return null;
  final block = _contentBlockOf(layout, hit.blockId);
  if (block == null) {
    return (
      start: _locatorOf(layout, hit.blockId, hit.lineStart),
      end: _locatorOf(layout, hit.blockId, hit.lineEnd),
    );
  }
  final text = blockTextOf(block);
  // 长按选出来的范围只落在本页：句子跨到上一页/下一页时，
  // 起点夹到本页第一行、终点夹到本页最后一行，
  // 这样两端手柄都看得见，不用先翻页才能调
  // 行偏移是「显示文本」坐标（含首行缩进前缀），块偏移是标准化坐标，比之前先换算
  final prefix = _prefixOf(layout, hit.blockId);
  final lines = _pageLinesOf(layout, pageIndex, hit.blockId);
  final minOffset = (lines?.$1 ?? prefix) - prefix;
  final maxOffset = (lines?.$2 ?? prefix + text.length) - prefix;
  int clampToPage(int offset) =>
      math.max(minOffset, math.min(maxOffset, offset));

  final spans = splitSentences(text);
  if (spans.isEmpty) {
    return (
      start: _locatorOf(layout, hit.blockId, clampToPage(0)),
      end: _locatorOf(layout, hit.blockId, clampToPage(text.length)),
    );
  }
  // 点在块末时（偏移等于整块长度）sentenceIndexAt 会返回句子数，
  // 取最后一句；不夹住会越界，长按到段落最后一行就会没反应
  final index = sentenceIndexAt(spans, hit.offset).clamp(0, spans.length - 1);
  final span = spans[index];
  final start = clampToPage(span.start);
  final end = clampToPage(span.end);
  if (end <= start) {
    return (
      start: _locatorOf(layout, hit.blockId, span.start),
      end: _locatorOf(layout, hit.blockId, span.end),
    );
  }
  return (
    start: _locatorOf(layout, hit.blockId, start),
    end: _locatorOf(layout, hit.blockId, end),
  );
}

/// 这一块的首行缩进前缀长度（块不在本章时为 0）
int _prefixOf(ChapterLayout layout, String blockId) {
  for (final block in layout.blocks) {
    if (block.blockId == blockId) return block.displayPrefixLength;
  }
  return 0;
}

/// 本页上这一块占了哪几行：返回（首行起点、末行终点）的显示偏移。
///
/// 这一块不在本页时返回 null（调用方按整块处理）。
(int, int)? _pageLinesOf(
  ChapterLayout layout,
  int pageIndex,
  String blockId,
) {
  final page = layout.page(pageIndex);
  if (page == null) return null;
  for (final fragment in page.fragments) {
    if (fragment.frameOnly) continue;
    final block = fragment.block;
    if (block.blockId != blockId || block.lines.isEmpty) continue;
    final first = block.lines[fragment.lineFrom.clamp(0, block.lines.length - 1)];
    final last =
        block.lines[(fragment.lineTo - 1).clamp(0, block.lines.length - 1)];
    return (first.start, last.end);
  }
  return null;
}

/// 内容盒里的一点 → 所在行的起始/结束偏移（手柄定位与整行回退用）。
({Locator start, Locator end})? lineRangeAtPointInPage({
  required ChapterLayout layout,
  required int pageIndex,
  required Offset position,
}) {
  final hit = _hitTest(layout: layout, pageIndex: pageIndex, position: position);
  if (hit == null) return null;
  return (
    start: _locatorOf(layout, hit.blockId, hit.lineStart),
    end: _locatorOf(layout, hit.blockId, hit.lineEnd),
  );
}

/// 命中测试的内部结果：哪一块、行内字符位置、这一行的标准化首尾偏移
({String blockId, int offset, int lineStart, int lineEnd})? _hitTest({
  required ChapterLayout layout,
  required int pageIndex,
  required Offset position,
}) {
  final page = layout.page(pageIndex);
  if (page == null) return null;

  for (final fragment in page.fragments) {
    if (fragment.frameOnly) continue;
    final block = fragment.block;
    if (block.tableBounds != null &&
        (position.dx < block.tableBounds!.left || position.dx > block.tableBounds!.right)) { continue; }
    if (block.lines.isEmpty) continue;
    if (position.dy < fragment.y ||
        position.dy > fragment.y + fragment.height) {
      continue;
    }
    var y = fragment.y;
    for (var i = fragment.lineFrom; i < fragment.lineTo; i++) {
      final line = block.lines[i];
      if (position.dy <= y + line.height || i == fragment.lineTo - 1) {
        // 显示文本偏移 → 标准化正文偏移（减掉首行缩进前缀）
        final prefix = block.displayPrefixLength;
        final maxOffset = math.max(0, block.text.length - prefix);
        final display = _offsetInLine(
          layout: layout,
          block: block,
          lineIndex: i,
          dx: position.dx,
        );
        final normalized = (display - prefix).clamp(0, maxOffset).toInt();
        return (
          blockId: block.blockId,
          offset: normalized,
          lineStart: (line.start - prefix).clamp(0, maxOffset).toInt(),
          lineEnd: (line.end - prefix).clamp(0, maxOffset).toInt(),
        );
      }
      y += line.height;
    }
  }
  return null;
}

/// 与绘制完全同一套参数（字号、字距、缩放）的单行 painter。
///
/// 命中测试、高亮矩形、手柄定位都必须用它：只要有一处另取参数，
/// 算出来的位置就和画出来的字对不上。
TextPainter _linePainter(
  ChapterLayout layout,
  MeasuredBlock block,
  int lineIndex,
) {
  final maxWidth = (block.layoutWidth ?? layout.options.contentWidthFor(block.kind));
  final justify = block.tableId == null && switch (block.kind) {
    BlockKind.paragraph || BlockKind.listItem || BlockKind.footnote => true,
    _ => false,
  };
  return block.createSingleLinePainter(
    lineIndex: lineIndex,
    textScaler: layout.options.textScaler,
    letterSpacing: block.justifySpacingFor(
      lineIndex,
      maxWidth: maxWidth,
      enabled: justify,
      textScaler: layout.options.textScaler,
    ),
  );
}

/// 行内横坐标 → 显示文本偏移。
///
/// 用与绘制完全同一套参数（同一 [TextScaler]、同一字距）把这一行单独排出来，
/// 再问它「这个 x 落在第几个字上」。两端对齐的行会按字距摊开，
/// 这里跟着算同一份字距，否则点到行尾会差出好几个字。
int _offsetInLine({
  required ChapterLayout layout,
  required MeasuredBlock block,
  required int lineIndex,
  required double dx,
}) {
  final line = block.lines[lineIndex];
  if (line.end <= line.start) return line.start;
  final painter = _linePainter(layout, block, lineIndex);
  // 行是从块的左内边距开始画的（列表项有缩进），比较前先减掉
  final position = painter.getPositionForOffset(
    Offset(dx - block.inset, line.height / 2),
  );
  painter.dispose();
  return (line.start + position.offset).clamp(line.start, line.end).toInt();
}

/// 版式里的块 ID → 原始正文块（摘录、句读切分要回到未加缩进的文本）
ContentBlock? _contentBlockOf(ChapterLayout layout, String blockId) {
  for (final block in layout.content.blocks) {
    if (block.id == blockId) return block;
  }
  return null;
}

/// 选区某端在页面上的光标位置（页内容盒坐标），手柄按它定位。
class CaretGeometry {
  const CaretGeometry({
    required this.left,
    required this.top,
    required this.height,
  });

  /// 字符边界的横坐标
  final double left;

  /// 所在行的上沿
  final double top;

  /// 行高
  final double height;

  double get bottom => top + height;
}

/// 某个位置的光标位置；不在这页（或块已被替换）时返回 null。
///
/// [atEnd] 表示这是选区的结束端：偏移正好落在换行处时，结束端贴在上一行末尾，
/// 起点端贴在下一行开头——与 `selectionRectsForPage` 的高亮画法保持一致。
CaretGeometry? caretAtLocator({
  required ChapterLayout layout,
  required int pageIndex,
  required Locator locator,
  required bool atEnd,
}) {
  if (locator.chapterId != layout.chapterId) return null;
  final page = layout.page(pageIndex);
  if (page == null) return null;
  for (final fragment in page.fragments) {
    if (fragment.frameOnly) continue;
    final block = fragment.block;
    if (block.blockId != locator.blockId || block.lines.isEmpty) continue;
    final display = (locator.utf16Offset + block.displayPrefixLength)
        .clamp(0, block.text.length);
    final matches = <({int index, double top})>[];
    var y = fragment.y;
    for (var i = fragment.lineFrom; i < fragment.lineTo; i++) {
      final line = block.lines[i];
      if (display >= line.start && display <= line.end) {
        matches.add((index: i, top: y));
      }
      y += line.height;
    }
    if (matches.isEmpty) continue;
    final target = atEnd ? matches.first : matches.last;
    final line = block.lines[target.index];
    final painter = _linePainter(layout, block, target.index);
    final caret = painter.getOffsetForCaret(
      TextPosition(offset: display - line.start),
      Rect.zero,
    );
    painter.dispose();
    return CaretGeometry(
      left: block.inset + caret.dx,
      top: target.top,
      height: line.height,
    );
  }
  return null;
}

/// 一页的首/末文本位置（拖动拖出页沿时按整页延伸选区）。
///
/// [atEnd] 为 true 取该页最后一个字，否则取第一个字；该页没有文本时返回 null。
Locator? pageEdgeLocator({
  required ChapterLayout layout,
  required int pageIndex,
  required bool atEnd,
}) {
  final page = layout.page(pageIndex);
  if (page == null) return null;
  final fragments = [
    for (final fragment in page.fragments)
      if (!fragment.frameOnly && fragment.block.lines.isNotEmpty) fragment,
  ];
  if (fragments.isEmpty) return null;
  final fragment = atEnd ? fragments.last : fragments.first;
  final block = fragment.block;
  final line = atEnd
      ? block.lines[fragment.lineTo - 1]
      : block.lines[fragment.lineFrom];
  final display = atEnd ? line.end : line.start;
  final normalized = (display - block.displayPrefixLength)
      .clamp(0, math.max(0, block.text.length - block.displayPrefixLength))
      .toInt();
  return _locatorOf(layout, block.blockId, normalized);
}

/// 把跨章选区裁到 [layout] 这一章：返回本章内的两端（按阅读顺序），
/// 本章完全不在范围内时返回 null。
///
/// 同一章内的选区原样返回；跨章时首章取到章末、末章从章首起、中间章整章。
(Locator, Locator)? clipRangeToChapter({
  required ChapterLayout layout,
  required Locator from,
  required Locator to,
  Map<String, int>? chapterOrdinals,
}) {
  if (from.chapterId == layout.chapterId && to.chapterId == layout.chapterId) {
    return (from, to);
  }
  if (chapterOrdinals == null) return null;
  final ordinals = chapterOrdinals;
  var start = from;
  var end = to;
  final orderStart = ordinals[from.chapterId] ?? kUnknownChapterOrdinal;
  final orderEnd = ordinals[to.chapterId] ?? kUnknownChapterOrdinal;
  if (orderStart > orderEnd) {
    start = to;
    end = from;
  }
  final chapterOrder = ordinals[layout.chapterId];
  final startOrder = ordinals[start.chapterId] ?? kUnknownChapterOrdinal;
  final endOrder = ordinals[end.chapterId] ?? kUnknownChapterOrdinal;
  if (chapterOrder == null) return null;
  if (chapterOrder < startOrder || chapterOrder > endOrder) return null;

  final chapterBegin = layout.pages.isEmpty
      ? null
      : layout.beginLocatorOf(layout.pages.first);
  final chapterEnd = layout.pages.isEmpty
      ? null
      : layout.endLocatorOf(layout.pages.last);
  if (start.chapterId == layout.chapterId) {
    if (end.chapterId == layout.chapterId) return (start, end);
    return chapterEnd == null ? null : (start, chapterEnd);
  }
  if (end.chapterId == layout.chapterId) {
    return chapterBegin == null ? null : (chapterBegin, end);
  }
  return (chapterBegin, chapterEnd).$1 == null
      ? null
      : (chapterBegin!, chapterEnd!);
}

/// 阅读顺序比较：先比块序号，再比块内偏移
bool _isBefore(
  ({int blockIndex, int offset}) a,
  ({int blockIndex, int offset}) b,
) =>
    a.blockIndex < b.blockIndex ||
    (a.blockIndex == b.blockIndex && a.offset <= b.offset);

/// 某一点的区块顺序键：块在章内的序号 + 块内偏移
({int blockIndex, int offset})? _keyOf(ChapterLayout layout, Locator locator) {
  for (var i = 0; i < layout.blocks.length; i++) {
    if (layout.blocks[i].blockId == locator.blockId) {
      return (blockIndex: i, offset: locator.utf16Offset);
    }
  }
  return null;
}

Locator _locatorOf(ChapterLayout layout, String blockId, int offset) => Locator(
      bookId: layout.bookId,
      contentVersion: layout.contentVersion,
      chapterId: layout.chapterId,
      blockId: blockId,
      utf16Offset: offset,
    );

/// 一段文本范围的首页与末页（用于判断选区跨了几页）
({int first, int last})? pagesOfRange({
  required ChapterLayout layout,
  required Locator from,
  required Locator to,
}) {
  final a = layout.pageIndexOf(from);
  final b = layout.pageIndexOf(to);
  if (a == null || b == null) return null;
  return (first: math.min(a, b), last: math.max(a, b));
}

/// 供界面判断一页是否被选区覆盖（含跨页的中间页）
bool pageInRange({
  required ChapterLayout layout,
  required int pageIndex,
  required Locator from,
  required Locator to,
}) {
  final range = pagesOfRange(layout: layout, from: from, to: to);
  if (range == null) return false;
  return pageIndex >= range.first && pageIndex <= range.last;
}
