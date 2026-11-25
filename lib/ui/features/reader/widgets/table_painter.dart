import 'reader_link_ink.dart';

import 'package:flutter/painting.dart';

import '../../../../engine/layout/chapter_paginator.dart';
import '../../../../engine/layout/collapsed_table_borders.dart';
import '../../../../engine/layout/layout_options.dart';
import '../../../core/theme/reading_theme.dart';
import 'reader_text_painter.dart';
import 'css_background_paint.dart';
import 'book_box_paint.dart';
import 'book_colors.dart';

void paintTableFragments(
  Canvas canvas,
  List<PageFragment> fragments,
  LayoutOptions options,
  Color text,
  Color rule, {
  ReadingTheme? theme,
  BookImageLookup? images,
  Color? backdrop,
  LinkAppearance? links,
}) {
  final readingTheme = theme ?? ReadingTheme.paper;
  paintTableFrames(canvas, fragments, rule, readingTheme, images: images);
  for (final fragment in fragments) {
    final block = fragment.block;
    if (fragment.frameOnly || block.imageSize != null) continue;
    ReaderTextPainter(
      options,
      readingTheme,
      images: images,
      links: links,
      backgroundColor: backdrop,
    ).paint(
      canvas,
      Size(options.contentWidth, options.contentHeight),
      fragment,
    );
  }
}

/// 先画格子底色，再画共享线，避免后画的单元格盖住边线的另一半。
void paintTableFrames(
  Canvas canvas,
  List<PageFragment> fragments,
  Color rule,
  ReadingTheme theme, {
  BookImageLookup? images,
}) {
  final collapsed = <(String, bool), List<PageFragment>>{};
  for (final fragment in fragments) {
    if (fragment.paintedTableFrame == null) continue;
    if (fragment.block.collapsedTableBorders) {
      (collapsed[(fragment.block.tableId!, fragment.repeatedTableFrame)] ??= [])
          .add(fragment);
    }
    _paintTableFrame(canvas, fragment, rule, theme, images: images);
  }
  for (final cells in collapsed.values) {
    final vertical =
        <({double x, double top, double bottom}), CollapsedBorder>{};
    final rowPositions = <double, double>{};
    for (final f in cells) {
      if (f.tableTopEdge) {
        rowPositions[f.block.tableBounds!.top] = f.paintedTableFrame!.top;
      }
      if (f.tableBottomEdge) {
        rowPositions[f.block.tableBounds!.bottom] = f.paintedTableFrame!.bottom;
      }
    }
    final clippedBottoms = <({double y, double left, double right})>{};
    final horizontal =
        <({double y, double left, double right}), CollapsedBorder>{};
    for (var i = 0; i < cells.length; i++) {
      final fragment = cells[i];
      final rect = fragment.paintedTableFrame!;
      final block = fragment.block;
      final original = block.tableBounds!;
      for (final edge
          in fragment.tablePageBorders ?? block.tableVerticalBorders) {
        // 完整行边界以实际分页位置为准。被本页截断的两端只画到格框边缘。
        double at(double v) =>
            (rowPositions[v] ??
                    (fragment.tableBottomEdge
                        ? rect.bottom + v - original.bottom
                        : rect.top + v - original.top))
                .clamp(rect.top, rect.bottom);
        final local = fragment.tablePageBorders != null;
        final top = local
            ? edge.top
            : edge.top == original.top
            ? rect.top
            : at(edge.top);
        final bottom = local
            ? edge.bottom
            : edge.bottom == original.bottom
            ? rect.bottom
            : at(edge.bottom);
        if (bottom > top) {
          vertical[(
                x: edge.left ? rect.left : rect.right,
                top: top,
                bottom: bottom,
              )] =
              edge.border;
        }
      }
      for (final edge in block.tableHorizontalBorders) {
        if (edge.top ? !fragment.tableTopEdge : !fragment.tableBottomEdge) {
          continue;
        }
        if (edge.top && fragment.omitSharedTop) continue;
        final key = (
          y: edge.top ? rect.top : rect.bottom,
          left: edge.left,
          right: edge.right,
        );
        horizontal[key] = edge.border;
        if (!edge.top && fragment.clipSharedBottom) clippedBottoms.add(key);
      }
    }
    final junctions = <Offset, _BorderJunction>{};
    void register(bool across, Offset point, CollapsedBorder border) {
      (junctions[point] ??= _BorderJunction()).add(across, border);
    }

    for (final MapEntry(key: e, value: border) in horizontal.entries) {
      register(true, Offset(e.left, e.y), border);
      register(true, Offset(e.right, e.y), border);
    }
    for (final MapEntry(key: e, value: border) in vertical.entries) {
      register(false, Offset(e.x, e.top), border);
      register(false, Offset(e.x, e.bottom), border);
    }
    final transform = canvas.getTransform();
    double snap(double value, int axis) {
      final scale = transform[axis == 0 ? 0 : 5], origin = transform[12 + axis];
      if (scale <= 0 || transform[1] != 0 || transform[4] != 0) return value;
      return ((value * scale + origin).roundToDouble() - origin) / scale;
    }

    void draw(
      bool horizontal,
      double at,
      double start,
      double end,
      CollapsedBorder edge,
    ) {
      Offset point(double along) =>
          horizontal ? Offset(along, at) : Offset(at, along);
      start -= junctions[point(start)]?.extension(horizontal) ?? 0;
      end += junctions[point(end)]?.extension(horizontal) ?? 0;
      if (end <= start) return;
      final half = edge.width / 2;
      final area = horizontal
          ? Rect.fromLTRB(start, at - half, end, at + half)
          : Rect.fromLTRB(at - half, start, at + half, end);
      // 在当前设备像素上落线；1px 实线位于小数行高处时仍有一个完整色带。
      final snapped = Rect.fromLTRB(
        snap(area.left, 0),
        snap(area.top, 1),
        snap(area.right, 0),
        snap(area.bottom, 1),
      );
      paintStraightCssBorder(canvas, snapped, edge.side, switch (edge.style) {
        7 => 6,
        8 => 5,
        _ => edge.style,
      }, adaptBorder(edge.color, theme.background));
    }

    for (final MapEntry(key: edge, value: border) in vertical.entries) {
      draw(false, edge.x, edge.top, edge.bottom, border);
    }
    for (final MapEntry(key: edge, value: border) in horizontal.entries) {
      final clip = clippedBottoms.contains(edge);
      if (clip) {
        canvas.save();
        final half = border.width / 2;
        canvas.clipRect(
          Rect.fromLTRB(
            edge.left - half,
            edge.y - half,
            edge.right + half,
            edge.y,
          ),
        );
      }
      draw(true, edge.y, edge.left, edge.right, border);
      if (clip) canvas.restore();
    }
  }
}

/// 在交点给两组相交边分配面积。外角伸出半条相邻线的宽度；贯通线
/// 两段在同一个中心对接，不重复涂色，也不把边画进无关单元格。
class _BorderJunction {
  CollapsedBorder? horizontal, vertical;
  int hCount = 0, vCount = 0;
  void add(bool across, CollapsedBorder edge) {
    if (across) {
      hCount++;
      if (horizontal == null || compareTableLine(edge, horizontal!) > 0) {
        horizontal = edge;
      }
    } else {
      vCount++;
      if (vertical == null || compareTableLine(edge, vertical!) > 0) {
        vertical = edge;
      }
    }
  }

  double extension(bool across) {
    if (horizontal == null || vertical == null) return 0;
    final wins = compareTableLine(horizontal!, vertical!) >= 0;
    final half = (across ? vertical!.width : horizontal!.width) / 2;
    if (across == wins) return (across ? hCount : vCount) == 1 ? half : 0;
    return -half;
  }
}

/// 跨页单元格只画实际存在的边；页尾切片不是单元格的底部。
void _paintTableFrame(
  Canvas canvas,
  PageFragment fragment,
  Color rule,
  ReadingTheme theme, {
  BookImageLookup? images,
}) {
  final rect = fragment.paintedTableFrame!;
  final block = fragment.block;
  if (block.tableUnit == 0) {
    if (block.tableBackdrops.isNotEmpty) {
      final original = block.tableBounds!;
      final shift = Offset(
        rect.left - original.left,
        fragment.tableTopEdge
            ? rect.top - original.top
            : rect.bottom - original.bottom,
      );
      canvas.save();
      canvas.clipRect(rect);
      for (final layer in block.tableBackdrops) {
        paintBookBoxRect(
          canvas,
          rect,
          layer.box,
          theme,
          backgroundArea: layer.area.shift(shift),
          topEdge: false,
          bottomEdge: false,
          leftEdge: false,
          rightEdge: false,
          images: images,
        );
      }
      canvas.restore();
    }
    final box = block.tableCellBox;
    if (box != null) {
      paintBookBoxRect(
        canvas,
        rect,
        box,
        theme,
        topEdge: fragment.tableTopEdge && !block.collapsedTableBorders,
        bottomEdge: fragment.tableBottomEdge && !block.collapsedTableBorders,
        leftEdge: !block.collapsedTableBorders,
        rightEdge: !block.collapsedTableBorders,
        images: images,
      );
    }
    return;
  }
  if (block.tableHeader) {
    canvas.drawRect(rect, Paint()..color = rule.withValues(alpha: .08));
  }
  final path = Path()
    ..moveTo(rect.left, rect.top)
    ..lineTo(rect.left, rect.bottom)
    ..moveTo(rect.right, rect.top)
    ..lineTo(rect.right, rect.bottom);
  if (fragment.tableTopEdge) {
    path
      ..moveTo(rect.left, rect.top)
      ..lineTo(rect.right, rect.top);
  }
  if (fragment.tableBottomEdge) {
    path
      ..moveTo(rect.left, rect.bottom)
      ..lineTo(rect.right, rect.bottom);
  }
  canvas.drawPath(
    path,
    Paint()
      ..color = rule.withValues(alpha: .3)
      ..style = PaintingStyle.stroke
      ..strokeWidth = .7,
  );
}
