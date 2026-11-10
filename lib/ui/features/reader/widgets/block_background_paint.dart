import 'dart:math' as math;

import 'package:flutter/painting.dart';

import '../../../../domain/models/book_document.dart';
import '../../../../engine/layout/chapter_paginator.dart';
import '../../../../engine/layout/layout_options.dart';
import '../../../../engine/layout/measured_block.dart';
import '../../../core/theme/reading_theme.dart';
import 'book_box_paint.dart';
import 'css_background_paint.dart';

/// 分页与滚动共用：先画显示树的外层容器，再画块自己的盒子，最后画容器内的代码框。
void paintBlockBackgrounds(
  Canvas canvas,
  List<PageFragment> fragments,
  LayoutOptions options,
  ReadingTheme theme, {
  bool paginated = false,
  BookImageLookup? images,
  Map<int, Rect> backgroundAreas = const {},
}) {
  final pageHeight = paginated ? options.contentHeight : null;
  _paintContainers(
    canvas,
    fragments,
    theme,
    pageHeight,
    images,
    backgroundAreas,
  );
  // 书内盒子与代码底色先画：高亮、选区和文字都压在它上面。
  // 同一个容器的连续片段合成一个整体矩形再画，逐块拼接会在块与块之间留下白缝。
  final boxRuns = <int, List<PageFragment>>{};
  final boxRunOrder = <int>[];
  for (final fragment in fragments) {
    // 表格在引用框里时，分页会补一个只画盒子、不画文字的片段；
    // 其余 frameOnly（表格单元格边框、图片占位）照旧跳过。
    if (fragment.frameOnly && fragment.block.box == null) continue;
    final block = fragment.block;
    final boxId = block.boxId;
    if (block.box != null && boxId != null) {
      final run = boxRuns[boxId];
      if (run == null) {
        boxRuns[boxId] = [fragment];
        boxRunOrder.add(boxId);
      } else {
        run.add(fragment);
      }
      continue;
    }
  }
  for (final boxId in boxRunOrder) {
    _paintBoxRun(canvas, boxRuns[boxId]!, options, theme, pageHeight, images);
  }
  // 内层代码框后画，外层引用底色才不会盖住它。
  for (final fragment in fragments) {
    final block = fragment.block;
    if (block.kind != BlockKind.codeBlock) continue;
    final inner = block.codeBox;
    if (inner != null) {
      final first = fragment.lineFrom == 0;
      final last = fragment.lineTo == block.lines.length;
      final top = first ? block.bodyTop - inner.insetTop : 0.0;
      final bottom = last ? block.bodyBottom - inner.insetBottom : 0.0;
      paintBookBoxRect(
        canvas,
        _continuedRect(
          Rect.fromLTWH(
            block.inset - inner.insetLeft,
            fragment.y + top,
            (block.layoutWidth ?? options.contentWidth) +
                inner.insetLeft +
                inner.insetRight,
            fragment.height - top - bottom,
          ),
          first,
          last,
          pageHeight,
        ),
        inner,
        theme,
        topEdge: first,
        bottomEdge: last,
        images: images,
      );
    }
  }
}

/// 把一页上属于同一个外层容器的片段合成一个矩形，从外到内依次画。
///
/// 外层先画、内层后画，背景不会盖住内层；首片带顶边框、末片带底边框。
void _paintContainers(
  Canvas canvas,
  List<PageFragment> fragments,
  ReadingTheme theme,
  double? pageHeight,
  BookImageLookup? images,
  Map<int, Rect> backgroundAreas,
) {
  final runs = <int, List<(Rect, ContainerBoxFrame, bool, bool)>>{};
  for (final fragment in fragments) {
    if (fragment.block.tableId != null && !fragment.block.isTableBox) continue;
    for (final frame in fragment.block.containerBoxes) {
      final part = containerBackgroundPart(fragment, frame);
      if (part != null) (runs[frame.elementId] ??= []).add(part);
    }
  }
  // DOM 元素编号为前序：父框一定先于子框，空元素和块内范围也遵守它。
  final ids = runs.keys.toList()..sort();
  for (final id in ids) {
    final run = runs[id]!;
    final first = run.first, last = run.last;
    final rect = _continuedRect(
      Rect.fromLTRB(
        first.$1.left,
        first.$1.top,
        first.$1.right,
        last.$1.bottom,
      ),
      first.$3,
      last.$4,
      pageHeight,
    );
    if (rect.height <= 0) continue;
    paintBookBoxRect(
      canvas,
      rect,
      first.$2.box,
      theme,
      topEdge: first.$3,
      bottomEdge: last.$4,
      images: images,
      backgroundArea: backgroundAreas[id],
    );
  }
}

/// 分页时框的空白部分也属于原容器：续页从页顶接上，未结束的框延伸到
/// 正文区页尾。只扩大装饰矩形，不改行高、分页锚点或滚动块的实际高度。
Rect _continuedRect(Rect rect, bool first, bool last, double? pageHeight) =>
    pageHeight == null
    ? rect
    : Rect.fromLTRB(
        rect.left,
        first ? rect.top : 0,
        rect.right,
        last ? rect.bottom : math.max(rect.bottom, pageHeight),
      );

/// 显示框与本次页/滚动片段的交集。块内框按行范围裁剪；父层的上下
/// 留白只在真实首尾扣除，中间续页不能重复加顶边或减底边。
(Rect, ContainerBoxFrame, bool, bool)? containerBackgroundPart(
  PageFragment fragment,
  ContainerBoxFrame frame,
) {
  final block = fragment.block;
  var top = fragment.y, bottom = fragment.y + fragment.height;
  var first = frame.first, last = frame.last;
  if (block.lines.isNotEmpty) {
    final start = math.max(fragment.lineFrom, frame.lineFrom);
    final end = math.min(fragment.lineTo, frame.lineTo ?? block.lines.length);
    if (end <= start) return null;
    if (start > fragment.lineFrom) {
      top += block.textTopOf(fragment.lineFrom);
      for (var i = fragment.lineFrom; i < start; i++) {
        top += block.lines[i].height;
      }
    }
    if (end < fragment.lineTo) {
      bottom = fragment.y + block.textTopOf(fragment.lineFrom);
      for (var i = fragment.lineFrom; i < end; i++) {
        bottom += block.lines[i].height;
      }
    }
    first = first && start == frame.lineFrom;
    last = last && end == (frame.lineTo ?? block.lines.length);
  }
  if (first) top += frame.top;
  if (frame.height != null) {
    bottom = math.min(bottom, top + frame.height!);
  } else if (last) {
    bottom -= frame.bottom;
  }
  if (bottom <= top) return null;
  return (
    Rect.fromLTWH(frame.left, top, frame.width, bottom - top),
    frame,
    first,
    last,
  );
}

/// 把一页上属于同一个容器的连续片段合成一个矩形画盒子。
///
/// 以前是逐块画背景，块高的取整差会在块与块之间漏出纸面白缝；整段只画一次
/// 背景、边框、圆角和阴影，就不会有缝。跨页时首片带顶边框、末片带底边框。
void _paintBoxRun(
  Canvas canvas,
  List<PageFragment> run,
  LayoutOptions options,
  ReadingTheme theme,
  double? pageHeight,
  BookImageLookup? images,
) {
  if (run.isEmpty) return;
  final first = run.first;
  final last = run.last;
  final block = first.block;
  final box = block.box;
  if (box == null) return;
  // 盒子属于外层容器：列表项自己的列表缩进（boxIndent）不能把盒子一起推右，
  // 否则翻到列表页时引用框会变窄、错位。
  final outsideWidth =
      (block.layoutWidth ?? options.contentWidth) +
      box.insetLeft +
      box.insetRight +
      block.boxIndent +
      (block.codeBox?.insetRight ?? 0);
  final firstEdge = first.block.boxFirst && first.lineFrom == 0;
  final lastEdge = last.block.boxLast && last.lineTo == last.block.lines.length;
  final rect = _continuedRect(
    Rect.fromLTWH(
      block.inset - box.insetLeft - block.boxIndent,
      first.y + (first.lineFrom == 0 ? block.bodyTop - box.insetTop : 0),
      outsideWidth,
      last.y +
          last.height -
          first.y -
          (first.lineFrom == 0 ? block.bodyTop - box.insetTop : 0) -
          (last.lineTo == last.block.lines.length
              ? last.block.bodyBottom - box.insetBottom
              : 0),
    ),
    firstEdge,
    lastEdge,
    pageHeight,
  );
  paintBookBoxRect(
    canvas,
    rect,
    box,
    theme,
    topEdge: firstEdge,
    bottomEdge: lastEdge,
    images: images,
  );
}
