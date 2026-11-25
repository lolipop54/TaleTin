import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../../../../engine/layout/book_background.dart';
import '../../../../engine/layout/chapter_paginator.dart';
import '../../../../engine/layout/scroll_chapter.dart';
import '../../../core/theme/reading_theme.dart';
import '../view_models/scroll_window.dart';
import 'book_box_paint.dart';
import 'scroll_resources.dart';
import 'page_information.dart';
import 'book_colors.dart';

final _cellAreas = Expando<Map<ScrollCell, Map<int, Rect>>>();

/// 滚动列表按小块显示，但背景的定位与 cover 尺寸必须属于完整容器，
/// 不能在每段正文重新从图顶开始。缓存只依附于本次测量结果。
Map<int, Rect> scrollBackgroundAreas(ScrollChapter chapter, ScrollCell cell) {
  final areas = _cellAreas[chapter] ??= (() {
    final result = <int, Rect>{};
    final ids = <ScrollCell, Set<int>>{};
    for (var i = 0; i < chapter.cells.length; i++) {
      final current = chapter.cells[i], start = chapter.starts[i];
      final fragments = current.table.isNotEmpty
          ? current.table
          : [
              PageFragment(
                block: current.measured,
                lineFrom: current.from,
                lineTo: current.to,
                y: current.gap,
                height: current.paintHeight,
              ),
            ];
      for (final fragment in fragments) {
        for (final frame in backgroundFrames(fragment.block, includePlainBox: true)) {
          final part = containerBackgroundPart(fragment, frame);
          if (part == null) continue;
          (ids[current] ??= {}).add(frame.elementId);
          final rect = part.$1.shift(Offset(0, start));
          result[frame.elementId] =
              result[frame.elementId]?.expandToInclude(rect) ?? rect;
        }
      }
    }
    // 每格只使用穿过它的容器。长章滚动时不再为新出现的每段复制全章所有背景框。
    return {
      for (var i = 0; i < chapter.cells.length; i++)
        if (ids[chapter.cells[i]] case final used?)
          chapter.cells[i]: {
            for (final id in used)
              id: result[id]!.shift(Offset(0, -chapter.starts[i])),
          },
    };
  })();
  return areas[cell] ?? const {};
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
      final chapterArea = Rect.fromLTWH(
        0,
        contentTop + before - offset,
        size.width,
        chapter.height,
      );
      final viewport = Rect.fromLTWH(
        0,
        contentTop,
        size.width,
        options.contentHeight,
      );
      final visible = chapterArea.intersect(viewport);
      if (!visible.isEmpty) {
        final box = chapter.paperBox ?? chapterBackground(chapter.content, options);
        if (box != null) {
          final style = box.backgroundImage?.style;
          final fixed = style?.attachment == 'fixed';
          final area = scrollPaperArea(
            chapterArea,
            viewport,
            fixed: fixed,
            imageHeight: chapter.paperImageHeight,
          );
          paintBookBoxRect(
            canvas,
            visible,
            box,
            theme,
            images: resources.backgroundInfo,
            backgroundArea: area,
          );
        }
      }
      before = after;
    }
  }

  @override
  bool shouldRepaint(ScrollCssBackgroundPainter old) => true;
}

/// 每章只有一个背景原点。纹理是否平铺由 CSS 绘制器决定；
/// fixed 随视口移动，到章尾时仍限制在本章内。
Rect scrollPaperArea(
  Rect chapter,
  Rect viewport, {
  required bool fixed,
  double? imageHeight,
}) {
  // 出版物的整页原画按自身比例占位，纸面高于视口时通过滚动看完。
  final height = imageHeight ?? math.min(chapter.height, viewport.height);
  final top = fixed
      ? viewport.top.clamp(
        chapter.top,
        math.max(chapter.top, chapter.bottom - height),
      ).toDouble()
      : chapter.top;
  return Rect.fromLTWH(chapter.left, top, chapter.width, height);
}

/// 滚动中只有跨入不同底色的章节才需要改变信息栏的文字颜色。
PageInformation scrollInformation(
  PageInformation info,
  ScrollWindow window,
  ScrollResources resources,
  ReadingTheme theme,
) {
  final options = window.options;
  final chapter = window.visible()?.entry.layout ?? window.entries.firstOrNull?.layout;
  if (options == null || chapter == null) return info;
  final backdrop = resources.backdropOf(chapter, options, theme);
  final color = adaptInk(
    info.color,
    backdrop,
    backdrop.computeLuminance() < .4 ? const Color(0xffeeeeee) : info.color,
  );
  return info.color == color ? info : info.withColor(color);
}
