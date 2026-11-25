import 'dart:math' as math;

import 'package:flutter/painting.dart';

import '../../../../domain/models/book_document.dart';
import '../../../../engine/layout/chapter_paginator.dart';
import '../../../../engine/layout/layout_options.dart';
import '../../../../engine/layout/measured_block.dart';
import '../../../core/theme/reading_theme.dart';
export '../../../../engine/layout/chapter_paginator.dart'
    show containerBackgroundPart;
import 'book_box_paint.dart';
import 'book_shadow_paint.dart';
import 'css_background_paint.dart';

/// 图片边框和阴影跟图片在同一层，后面的书封才能把阴影投到先画的书架上。
void paintImageBox(
  Canvas canvas,
  Rect rect,
  BlockBox box,
  ReadingTheme theme, {
  BookImageLookup? images,
  BookShadowPainter paintShadows = paintBookShadows,
}) {
  paintBookBoxRect(
    canvas,
    Rect.fromLTRB(
      rect.left - box.insetLeft,
      rect.top - box.insetTop,
      rect.right + box.insetRight,
      rect.bottom + box.insetBottom,
    ),
    box,
    theme,
    images: images,
    paintShadows: paintShadows,
  );
}

/// 分页与滚动共用：先画显示树的外层容器，再画块自己的盒子，最后画容器内的代码框。
void paintBlockBackgrounds(
  Canvas canvas,
  List<PageFragment> fragments,
  LayoutOptions options,
  ReadingTheme theme, {
  bool paginated = false,
  bool paintImageBoxes = true,
  BookShadowPainter paintShadows = paintBookShadows,
  BookImageLookup? images,
  Map<int, Rect> backgroundAreas = const {},
  double? scrollCellHeight,
}) {
  final pageHeight = paginated ? options.contentHeight : null;
  final geometry = containerPageGeometry(
    fragments,
    pageHeight,
    includePlainBox: scrollCellHeight != null,
  );
  final legends = <int, Rect>{};
  for (final fragment in fragments) {
    final block = fragment.block, id = block.legendFieldset;
    if (id != null &&
        fragment.lineFrom == 0 &&
        !fragment.frameOnly &&
        block.lines.isNotEmpty) {
      legends[id] = Rect.fromLTWH(
        block.inset - 2,
        fragment.y + block.textTopOf(0),
        (block.layoutWidth ?? block.lines.first.width) + 4,
        block.lines.first.height,
      );
    }
  }
  void paintContainer(int id, ContainerPageGeometry piece) =>
      _paintContainerPiece(
        canvas,
        piece,
        theme,
        images,
        backgroundAreas[id],
        paintShadows,
        scrollCellHeight,
        legends[id],
      );
  // 显示树的父容器先画，块自己的背景随后画，内框不会被外框遮住。
  final ids = geometry.keys.where((id) => id >= 0).toList()..sort();
  for (final id in ids) {
    paintContainer(id, geometry[id]!);
  }
  // 书内盒子与代码底色先画：高亮、选区和文字都压在它上面。
  // 同一个容器的连续片段合成一个整体矩形再画，逐块拼接会在块与块之间留下白缝。
  final boxRuns = <int, List<PageFragment>>{};
  final boxRunOrder = <int>[];
  for (final fragment in fragments) {
    // 表格在引用框里时，分页会补一个只画盒子、不画文字的片段；
    // 其余 frameOnly（表格单元格边框、图片占位）照旧跳过。
    if (fragment.frameOnly && fragment.block.box == null) continue;
    final block = fragment.block;
    if (block.imageSize != null) {
      final image = fragment.imageRectIn(options.contentWidth);
      final box = block.box;
      if (paintImageBoxes && image != null && box != null) {
        paintImageBox(
          canvas,
          image,
          box,
          theme,
          images: images,
          paintShadows: paintShadows,
        );
      }
      continue;
    }
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
    final key = blockBackgroundKey(boxId);
    final piece = geometry[key];
    if (piece != null) {
      paintContainer(key, piece);
    } else {
      _paintBoxRun(
        canvas,
        boxRuns[boxId]!,
        options,
        theme,
        pageHeight,
        images,
        paintShadows,
      );
    }
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
        paintShadows: paintShadows,
      );
    }
  }
}

void _paintContainerPiece(
  Canvas canvas,
  ContainerPageGeometry piece,
  ReadingTheme theme,
  BookImageLookup? images,
  Rect? area,
  BookShadowPainter paintShadows,
  double? scrollCellHeight,
  Rect? legend,
) {
  var rect = piece.rect;
  if (legend != null && piece.topEdge) {
    final y = legend.center.dy.clamp(rect.top, rect.bottom);
    rect = Rect.fromLTRB(rect.left, y, rect.right, rect.bottom);
    if (area != null) {
      area = Rect.fromLTRB(area.left, y, area.right, area.bottom);
    }
  }
  if (area != null && scrollCellHeight != null) {
    // 父框包括子块之间的留白。按整框画，只在列表单元交界处硬裁切，
    // 否则相邻两段各自抗锯齿，即使几何相接也会露出一行纸色。
    final top = math.min(0.0, rect.top);
    final bottom = math.max(scrollCellHeight, rect.bottom);
    final cutTop = area.top < top - .001;
    final cutBottom = area.bottom > bottom + .001;
    if (cutTop || cutBottom) {
      final clip = canvas.getLocalClipBounds();
      canvas.save();
      canvas.clipRect(
        Rect.fromLTRB(
          clip.left,
          cutTop ? top : clip.top,
          clip.right,
          cutBottom ? bottom : clip.bottom,
        ),
        doAntiAlias: false,
      );
    }
    paintBookBoxRect(
      canvas,
      area,
      piece.box,
      theme,
      images: images,
      backgroundArea: area,
      topBorderGap: legend,
      paintShadows: paintShadows,
    );
    if (cutTop || cutBottom) canvas.restore();
    return;
  }
  paintBookBoxRect(
    canvas,
    rect,
    piece.box,
    theme,
    topEdge: piece.topEdge,
    bottomEdge: piece.bottomEdge,
    images: images,
    backgroundArea: area,
    topBorderGap: legend,
    paintShadows: paintShadows,
  );
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
  BookShadowPainter paintShadows,
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
    paintShadows: paintShadows,
  );
}
