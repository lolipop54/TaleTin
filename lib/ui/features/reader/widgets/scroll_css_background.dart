import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../../../../engine/layout/book_background.dart';
import '../../../../engine/layout/chapter_paginator.dart';
import '../../../../engine/layout/scroll_chapter.dart';
import '../../../core/theme/reading_theme.dart';
import '../view_models/scroll_window.dart';
import 'block_background_paint.dart';
import 'book_box_paint.dart';
import 'scroll_resources.dart';
import 'page_information.dart';
import 'book_colors.dart';

final _areas = Expando<Map<int, Rect>>();
final _starts = Expando<Map<ScrollCell, double>>();

/// 滚动列表按小块显示，但背景的定位与 cover 尺寸必须属于完整容器，
/// 不能在每段正文重新从图顶开始。缓存只依附于本次测量结果。
Map<int, Rect> scrollBackgroundAreas(ScrollChapter chapter, ScrollCell cell) {
  final areas = _areas[chapter] ??= (() {
    final result = <int, Rect>{}, starts = <ScrollCell, double>{};
    for (var i = 0; i < chapter.cells.length; i++) {
      final current = chapter.cells[i], start = chapter.starts[i];
      starts[current] = start;
      final fragments = current.table.isNotEmpty
          ? current.table
          : [
              PageFragment(
                block: current.measured,
                lineFrom: current.from,
                lineTo: current.to,
                y: current.gap,
                height: current.height - current.gap - current.endGap,
              ),
            ];
      for (final fragment in fragments) {
        for (final frame in fragment.block.containerBoxes) {
          final part = containerBackgroundPart(fragment, frame);
          if (part == null) continue;
          final rect = part.$1.shift(Offset(0, start));
          result[frame.elementId] =
              result[frame.elementId]?.expandToInclude(rect) ?? rect;
        }
      }
    }
    _starts[chapter] = starts;
    return result;
  })();
  final start = _starts[chapter]![cell]!;
  return {
    for (final entry in areas.entries)
      entry.key: entry.value.shift(Offset(0, -start)),
  };
}

/// html/body 的背景传播到整张纸面；滚动时跟随它所属的章节，跨章不串图。
class ScrollCssBackgroundPainter extends CustomPainter {
  ScrollCssBackgroundPainter(
    this.window,
    this.resources,
    this.theme,
    this.contentTop,
  ) : super(repaint: Listenable.merge([window.controller, resources]));
  final ScrollWindow window;
  final ScrollResources resources;
  final ReadingTheme theme;
  final double contentTop;
  @override
  void paint(Canvas canvas, Size size) {
    final options = window.options;
    if (options == null || window.entries.isEmpty) return;
    final offset = window.controller.hasClients
        ? window.controller.offset
        : 0.0;
    var before = 0.0;
    for (var i = 0; i < window.entries.length; i++) {
      final chapter = window.entries[i].layout;
      final after = before + chapter.height;
      final top = before <= offset ? 0.0 : contentTop + before - offset;
      final bottom =
          after >= offset + options.contentHeight ||
              i == window.entries.length - 1
          ? size.height
          : contentTop + after - offset;
      if (bottom > 0 && top < size.height && bottom > top) {
        final box = chapterBackground(chapter.content, options);
        if (box != null) {
          canvas.save();
          canvas.clipRect(
            Rect.fromLTRB(
              0,
              math.max(0, top),
              size.width,
              math.min(size.height, bottom),
            ),
          );
          paintBookBoxRect(
            canvas,
            Rect.fromLTRB(0, top, size.width, bottom),
            box,
            theme,
            images: resources.backgroundInfo,
            backgroundArea: Rect.fromLTWH(
              0,
              before - offset,
              size.width,
              size.height,
            ),
          );
          canvas.restore();
        }
      }
      before = after;
    }
  }

  @override
  bool shouldRepaint(ScrollCssBackgroundPainter old) => true;
}

class CssScrollInformationPainter extends CustomPainter {
  CssScrollInformationPainter(
    this.info,
    this.window,
    this.resources,
    this.theme,
  ) : super(repaint: Listenable.merge([window.controller, resources]));
  final PageInformation info;
  final ScrollWindow window;
  final ScrollResources resources;
  final ReadingTheme theme;
  @override
  void paint(Canvas canvas, Size size) {
    final options = window.options;
    if (options == null || window.entries.isEmpty) {
      info.paint(canvas, size);
      return;
    }
    final offset = window.controller.hasClients ? window.controller.offset : 0;
    var before = 0.0;
    for (final entry in window.entries) {
      if (offset < before + entry.layout.height) {
        final backdrop = resources.backdropOf(entry.layout, options, theme);
        info
            .withColor(
              adaptInk(
                info.color,
                backdrop,
                backdrop.computeLuminance() < .4
                    ? const Color(0xffeeeeee)
                    : info.color,
              ),
            )
            .paint(canvas, size);
        return;
      }
      before += entry.layout.height;
    }
    info.paint(canvas, size);
  }

  @override
  bool shouldRepaint(CssScrollInformationPainter old) => true;
}
