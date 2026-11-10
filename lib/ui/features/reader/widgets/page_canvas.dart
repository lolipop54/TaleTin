/// 单页绘制：把排版结果画到画布上（实现计划 S8）。
///
/// 绘制与测量用同一份 [TextStyle]、同一个宽度：每个片段只取它在整块里的
/// 字符区间重新排版，贪心断行的结果与整块一致，因此页内的行位置与测量值完全吻合，
/// 不会出现「页尾整行空白」。
///
/// 图片先准备好，再和文字、选区一起绘制；页面准备期间保留旧画面。
library;

import 'package:flutter/material.dart';

import '../../../../engine/layout/chapter_layout.dart';
import '../../../../engine/layout/chapter_paginator.dart';
import '../../../../engine/layout/layout_options.dart';
import '../../../../engine/selection/selection_rects.dart' show CaretGeometry;
import '../../../../domain/models/book_document.dart';
import '../../../core/theme/reading_theme.dart';
import 'book_box_paint.dart';
import 'block_background_paint.dart';
import 'css_background_paint.dart';
import '../../../../engine/layout/book_background.dart';
import '../../../../engine/layout/measured_block.dart';
import 'reader_text_painter.dart';
import 'reader_divider_paint.dart';
import 'prepared_page_view.dart';
import 'table_painter.dart' show paintTableFrame;
import 'prepared_page.dart';
import 'page_information.dart';
import 'selection_handles.dart';
import 'thought_marker.dart';
import 'page_text_cache.dart';
export 'page_text_cache.dart' show PageTextCache;

class PageCanvas extends StatelessWidget {
  const PageCanvas({
    super.key,
    required this.layout,
    required this.pageIndex,
    required this.theme,
    required this.resolveResource,
    this.selectionRects = const [],
    this.selectionHandles = const [],
    this.handleColor = Colors.blue,
    this.speechRects = const [],
    this.highlights = const [],
    this.thoughtMarkers = const [],
    this.information,
    this.textCache,
    this.onReady,
    this.onPrepared,
  });

  final ChapterLayout layout;
  final int pageIndex;
  final ReadingTheme theme;
  final PageInformation? information;
  final PageTextCache? textCache;

  /// 公式 SVG 的 currentColor 在资源准备时解析，换主题后需要重新准备。
  Color? get formulaColor =>
      layout
              .page(pageIndex)
              ?.fragments
              .any(
                (f) => f.block
                    .inlineImagesInLines(f.lineFrom, f.lineTo)
                    .any((i) => i.formula != null),
              ) ==
          true
      ? theme.primary
      : null;

  /// 图片与正文齐备后报告当前页可绘制，供跳转遮盖判断何时撤去。
  final VoidCallback? onReady;

  /// 借出静态页已解码的图片；接收方需要长期保存时必须clone。
  final ValueChanged<PreparedPage>? onPrepared;

  /// 选区高亮矩形（页内容盒坐标，由引擎按选区算出来）
  final List<Rect> selectionRects;

  /// 两端只画在各自所在页上，翻页画布与截图也带上它们。
  final List<CaretGeometry> selectionHandles;
  final Color handleColor;
  final List<Rect> speechRects;

  /// 持久高亮（笔记与高亮记录）：铺在文字下面，颜色随主题
  final List<PageHighlight> highlights;
  final List<PageThoughtMarker> thoughtMarkers;

  /// 正文图片相对路径 → 绝对路径
  final String Function(String resourcePath) resolveResource;
  BlockBox? get cssBackground =>
      chapterBackground(layout.content, layout.options);
  Set<String> get backgroundPaths => {
    if (cssBackground?.backgroundImage case final background?) background.path,
    for (final f in layout.page(pageIndex)?.fragments ?? const <PageFragment>[])
      ...blockBackgroundPaths(f.block),
  };

  /// 只预备不变的文字／分隔线；选区、高亮、信息行仍在每次绘制时更新。
  void prepareText({Color? backdrop}) {
    final slice = layout.page(pageIndex), cache = textCache;
    if (slice == null || cache == null) return;
    final painter = _PagePainter(
      slice: slice,
      options: layout.options,
      theme: theme,
      backdrop: backdrop,
    );
    cache.prepare(
      layout,
      pageIndex,
      theme,
      (canvas) => painter.paint(canvas, layout.contentSize),
      backdrop: backdrop,
    );
  }

  /// 静态页和折页共用原有文字、装饰与选区画法；图片由准备好的页面补画。
  void paintText(Canvas canvas, {BookImageLookup? images, Color? backdrop}) {
    final slice = layout.page(pageIndex);
    if (slice == null) return;
    paintBlockBackgrounds(
      canvas,
      slice.fragments,
      layout.options,
      theme,
      paginated: true,
      images: images,
    );
    // 行内底色也必须在选文、笔记和听书高亮之前画，不能放进后绘制的文字缓存。
    for (final fragment in slice.fragments) {
      if (fragment.frameOnly) continue;
      final block = fragment.block;
      paintInlineBoxes(
        canvas,
        block,
        fragment.lineFrom,
        fragment.lineTo,
        fragment.y + block.textTopOf(fragment.lineFrom),
        block.layoutWidth ?? layout.options.contentWidthFor(block.kind),
        theme,
        images: images,
      );
    }
    for (final highlight in highlights) {
      _SelectionPainter(
        rects: highlight.rects,
        color: highlight.color,
      ).paint(canvas, layout.contentSize);
    }
    final speechPaint = Paint()..color = theme.speechHighlight;
    for (final rect in speechRects) {
      canvas.drawRect(rect, speechPaint);
    }
    _SelectionPainter(rects: selectionRects).paint(canvas, layout.contentSize);
    final painter = _PagePainter(
      slice: slice,
      options: layout.options,
      theme: theme,
      backdrop: backdrop,
    );
    final cache = textCache;
    if (cache == null) {
      painter.paint(canvas, layout.contentSize);
    } else {
      cache.paint(
        canvas,
        layout,
        pageIndex,
        theme,
        (target) => painter.paint(target, layout.contentSize),
        backdrop: backdrop,
      );
    }
    for (final mark in thoughtMarkers) {
      paintThoughtMarker(canvas, mark.rect, mark.color);
    }
    for (final caret in selectionHandles) {
      SelectionHandlePainter.paintAt(
        canvas,
        Offset(caret.left, caret.bottom),
        color: handleColor,
        lineHeight: caret.height,
      );
    }
  }

  @override
  Widget build(BuildContext context) => PreparedPageView(page: this);
}

/// 选区高亮：半透明底色，不做圆角与手柄（原型只验证矩形位置）
/// 一条持久高亮的绘制内容：一种颜色 + 它在这一页上的矩形
class PageHighlight {
  const PageHighlight({required this.color, required this.rects});

  final Color color;
  final List<Rect> rects;
}

class _SelectionPainter extends CustomPainter {
  const _SelectionPainter({
    required this.rects,
    this.color = kSelectionHighlight,
  });

  final List<Rect> rects;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    for (final rect in rects) {
      canvas.drawRect(rect, paint);
    }
  }

  @override
  bool shouldRepaint(_SelectionPainter oldDelegate) =>
      oldDelegate.rects != rects || oldDelegate.color != color;
}

/// 选区底色（沿用笔记高亮的浅蓝，深色主题下也看得清）
const Color kSelectionHighlight = Color(0x66B7D3F6);

class _PagePainter extends CustomPainter {
  const _PagePainter({
    required this.slice,
    required this.options,
    required this.theme,
    this.backdrop,
  });

  final PageSlice slice;

  /// 排版时用的参数：绘制只能用它，不能另取一份
  final LayoutOptions options;
  final ReadingTheme theme;
  final Color? backdrop;

  @override
  void paint(Canvas canvas, Size size) {
    for (final fragment in slice.fragments) {
      if (fragment.tableFrame case final frame?) {
        if (fragment.block.tableHeader) {
          canvas.drawRect(
            frame,
            Paint()..color = theme.secondary.withValues(alpha: .08),
          );
        }
        paintTableFrame(canvas, fragment, theme.secondary);
      }
      if (fragment.frameOnly) continue;
      switch (fragment.block.kind) {
        case BlockKind.image:
          break;
        case BlockKind.divider:
          paintReaderDivider(canvas, size, fragment, theme);
        case BlockKind.heading:
        case BlockKind.listItem:
        case BlockKind.paragraph:
        case BlockKind.quote:
        case BlockKind.codeBlock:
        case BlockKind.caption:
        case BlockKind.footnote:
          ReaderTextPainter(
            options,
            theme,
            backgroundColor: backdrop,
          ).paint(canvas, size, fragment, background: false);
      }
    }
  }

  @override
  bool shouldRepaint(_PagePainter old) =>
      old.slice != slice || old.theme != theme;
}
