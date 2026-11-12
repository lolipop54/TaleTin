/// 选区矩形与命中测试（实现计划 S15 / S1）。
///
/// 给定两个 Locator（选区两端）算出一页里每行的高亮矩形，把内容盒里的一点
/// 换算成**真实字符位置**，以及长按起选时给出命中的字或词。
///
/// 坐标口径：矩形都在**页内容盒**坐标系里（左上角为原点），与
/// `PageCanvas` 的绘制坐标一致——正文盒子在屏幕上居中，命中测试前
/// 调用方要先减掉盒子原点。
///
/// 行内落点用与绘制同一个 [TextPainter]（同样的字号、字距与缩放）反查字符，
/// 不再按字符数等比估算：估算在半角、标点、两端对齐的行上会偏出好一个字。
library;

import 'dart:math' as math;

import 'dart:ui' show Offset, Rect;

import '../../domain/models/book_document.dart';
import '../../domain/models/locator.dart';
import '../layout/chapter_layout.dart';
import '../layout/chapter_paginator.dart';
import '../layout/measured_block.dart';
import '../layout/line_text_geometry.dart';
import '../normalization/locator_mapper.dart';
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

    var y = fragment.y + block.textTopOf(fragment.lineFrom);
    for (var i = fragment.lineFrom; i < fragment.lineTo; i++) {
      final line = block.lines[i];
      final a = math.max(line.start, blockFrom);
      final b = math.min(line.end, selectTo);
      if (b > a) {
        rects.addAll(
          block
              .rangeRectsInLine(
                i,
                a,
                b,
                scaler: layout.options.textScaler,
                width: _widthOf(layout, block),
              )
              .map((r) => r.shift(Offset(0, y))),
        );
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
  final hit = _hitTest(
    layout: layout,
    pageIndex: pageIndex,
    position: position,
  );
  if (hit == null) return null;
  return _locatorOf(layout, hit.blockId, hit.offset);
}

/// 长按命中的字或词。单词跨页时夹在本页内，让两个手柄都能抓到。
Future<({Locator start, Locator end})?> initialSelectionAtPointInPage({
  required ChapterLayout layout,
  required int pageIndex,
  required Offset position,
}) async {
  final hit = _lineAtPoint(layout, pageIndex, position);
  if (hit == null || hit.fragment.block.isDecoration) return null;
  final measured = hit.fragment.block;
  final block = _contentBlockOf(layout, measured.blockId);
  if (block == null) return null;
  final range = await measured.initialSelectionInLine(
    hit.index,
    hit.point,
    scaler: layout.options.textScaler,
    width: _widthOf(layout, measured),
    source: blockTextOf(block),
  );
  if (range == null) return null;
  final prefix = measured.displayPrefixLength;
  final start = math.max(
    range.start,
    measured.lines[hit.fragment.lineFrom].start - prefix,
  );
  final end = math.min(
    range.end,
    measured.lines[hit.fragment.lineTo - 1].end - prefix,
  );
  if (end <= start) return null;
  return (
    start: _locatorOf(layout, block.id, start),
    end: _locatorOf(layout, block.id, end),
  );
}

/// 内容盒里的一点 → 所在行的起始/结束偏移（手柄定位与整行回退用）。
({Locator start, Locator end})? lineRangeAtPointInPage({
  required ChapterLayout layout,
  required int pageIndex,
  required Offset position,
}) {
  final hit = _hitTest(
    layout: layout,
    pageIndex: pageIndex,
    position: position,
  );
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
  final hit = _lineAtPoint(layout, pageIndex, position);
  if (hit == null) return null;
  final block = hit.fragment.block;
  final line = block.lines[hit.index];
  final prefix = block.displayPrefixLength;
  final maxOffset = math.max(0, block.text.length - prefix);
  final display = block.offsetAtInLine(
    hit.index,
    hit.point,
    scaler: layout.options.textScaler,
    width: _widthOf(layout, block),
  );
  int normalized(int offset) => (offset - prefix).clamp(0, maxOffset);
  return (
    blockId: block.blockId,
    offset: normalized(display),
    lineStart: normalized(line.start),
    lineEnd: normalized(line.end),
  );
}

({PageFragment fragment, int index, Offset point})? _lineAtPoint(
  ChapterLayout layout,
  int pageIndex,
  Offset position,
) {
  final page = layout.page(pageIndex);
  if (page == null) return null;

  for (final fragment in page.fragments) {
    if (fragment.frameOnly) continue;
    final block = fragment.block;
    if (block.tableBounds != null &&
        (position.dx < block.tableBounds!.left ||
            position.dx > block.tableBounds!.right)) {
      continue;
    }
    if (block.lines.isEmpty) continue;
    if (position.dy < fragment.y ||
        position.dy > fragment.y + fragment.height) {
      continue;
    }
    var y = fragment.y + block.textTopOf(fragment.lineFrom);
    for (var i = fragment.lineFrom; i < fragment.lineTo; i++) {
      final line = block.lines[i];
      if (position.dy <= y + line.height || i == fragment.lineTo - 1) {
        return (
          fragment: fragment,
          index: i,
          point: Offset(position.dx, position.dy - y),
        );
      }
      y += line.height;
    }
  }
  return null;
}

double _widthOf(ChapterLayout layout, MeasuredBlock block) =>
    block.layoutWidth ?? layout.options.contentWidthFor(block.kind);

/// 版式里的块 ID → 原始正文块（起选和摘录使用未加缩进的文字）。
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
    final display = (locator.utf16Offset + block.displayPrefixLength).clamp(
      0,
      block.text.length,
    );
    final matches = <({int index, double top})>[];
    var y = fragment.y + block.textTopOf(fragment.lineFrom);
    for (var i = fragment.lineFrom; i < fragment.lineTo; i++) {
      final line = block.lines[i];
      if (display >= line.start && display <= line.end) {
        matches.add((index: i, top: y));
      }
      y += line.height;
    }
    if (matches.isEmpty) continue;
    final target = atEnd ? matches.first : matches.last;
    final rect = block.caretRectInLine(
      target.index,
      display,
      atEnd,
      scaler: layout.options.textScaler,
      width: _widthOf(layout, block),
    );
    if (rect == null) continue;
    return CaretGeometry(
      left: rect.left,
      top: target.top + rect.top,
      height: rect.height,
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

  final chapterBegin = layout.pages.isEmpty ? null : layout.startLocator;
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
  if (layout.precedesWindow(locator)) return (blockIndex: -1, offset: 0);
  if (layout.followsTxtWindow(locator)) {
    return (blockIndex: layout.blocks.length, offset: 0);
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
