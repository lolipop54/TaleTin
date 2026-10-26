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
import '../../../../engine/layout/measured_block.dart';
import '../../../../engine/selection/selection_rects.dart' show CaretGeometry;
import '../../../../domain/models/book_document.dart';
import '../../../core/theme/reading_theme.dart';
import 'prepared_page_view.dart';
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

  /// 只预备不变的文字／分隔线；选区、高亮、信息行仍在每次绘制时更新。
  void prepareText() {
    final slice = layout.page(pageIndex), cache = textCache;
    if (slice == null || cache == null) return;
    final painter = _PagePainter(
      slice: slice,
      options: layout.options,
      theme: theme,
    );
    cache.prepare(
      layout,
      pageIndex,
      theme,
      (canvas) => painter.paint(canvas, layout.contentSize),
    );
  }

  /// 静态页和折页共用原有文字、装饰与选区画法；图片由准备好的页面补画。
  void paintText(Canvas canvas) {
    final slice = layout.page(pageIndex);
    if (slice == null) return;
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
  });

  final PageSlice slice;

  /// 排版时用的参数：绘制只能用它，不能另取一份
  final LayoutOptions options;
  final ReadingTheme theme;

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
        canvas.drawRect(
          frame,
          Paint()
            ..color = theme.secondary.withValues(alpha: .3)
            ..style = PaintingStyle.stroke
            ..strokeWidth = .7,
        );
      }
      if (fragment.frameOnly) continue;
      switch (fragment.block.kind) {
        case BlockKind.image:
          break;
        case BlockKind.divider:
          _paintDivider(canvas, size, fragment);
        case BlockKind.heading:
        case BlockKind.listItem:
        case BlockKind.paragraph:
        case BlockKind.footnote:
          _paintText(canvas, size, fragment);
      }
    }
  }

  void _paintText(Canvas canvas, Size size, PageFragment fragment) {
    final block = fragment.block;
    if (block.lines.isEmpty) return;
    final line = block.lines[fragment.lineFrom];
    // 与测量用的是同一个宽度，不用盒子宽度：两者一旦不等，行尾就会留白
    final maxWidth = block.layoutWidth ?? options.contentWidthFor(block.kind);
    final justify =
        block.tableId == null &&
        switch (block.kind) {
          BlockKind.paragraph ||
          BlockKind.listItem ||
          BlockKind.footnote => true,
          _ => false,
        };

    var index = fragment.lineFrom;
    var top = fragment.y;
    while (index < fragment.lineTo) {
      final spacing = block.justifySpacingFor(
        index,
        maxWidth: maxWidth,
        enabled: justify,
        textScaler: options.textScaler,
      );
      // 不需要拉伸的连续行合并成一次绘制，减少 TextPainter 数量
      var end = index + 1;
      if (spacing <= 0 && !block.lines[index].hyphenated) {
        while (end < fragment.lineTo &&
            !block.lines[end].hyphenated &&
            block.justifySpacingFor(
                  end,
                  maxWidth: maxWidth,
                  enabled: justify,
                  textScaler: options.textScaler,
                ) <=
                0) {
          end++;
        }
      }
      final painter = block.createFragmentPainter(
        lineFrom: index,
        lineTo: end,
        textScaler: options.textScaler,
        maxWidth: maxWidth,
        color: theme.primary,
        letterSpacing: spacing,
      );
      // 重排出来的行数必须和测量一致，否则按测量位置落笔就会错位：多出来的一行
      // 会压在下一行上——真机实测过（行宽正好顶到内容宽 + 行尾标点被字体回退取成
      // 更宽的写法，整行多折一次），页面上两个字叠在一起，看着像少了字。
      // 这种就逐行画：单行不给断行宽度，不可能再折行，只会往右多出一点。
      if (painter.computeLineMetrics().length == end - index) {
        painter.paint(canvas, Offset(block.inset, top));
        painter.dispose();
        for (var i = index; i < end; i++) {
          top += block.lines[i].height;
        }
      } else {
        painter.dispose();
        for (var i = index; i < end; i++) {
          final lineSpacing = block.justifySpacingFor(
            i,
            maxWidth: maxWidth,
            enabled: justify,
            textScaler: options.textScaler,
          );
          final linePainter = block.createSingleLinePainter(
            lineIndex: i,
            textScaler: options.textScaler,
            color: theme.primary,
            letterSpacing: lineSpacing,
          );
          linePainter.paint(canvas, Offset(block.inset, top));
          linePainter.dispose();
          top += block.lines[i].height;
        }
      }
      index = end;
    }

    // 章题下的短分隔线（参考图 03 的章首样式）
    if (block.isTitleDecoration) {
      final ruleTop = fragment.y + block.height - kTitleRuleThickness;
      canvas.drawRect(
        Rect.fromLTWH(0, ruleTop, kTitleRuleWidth, kTitleRuleThickness),
        Paint()..color = theme.secondary.withValues(alpha: 0.66),
      );
    }
    // 列表项圆点：装饰元素，不进入文本流
    if (block.kind == BlockKind.listItem && !fragment.isContinuation) {
      final radius = block.inset * 0.16;
      canvas.drawCircle(
        Offset(block.inset * 0.45, fragment.y + line.height * 0.5),
        radius,
        Paint()..color = theme.secondary,
      );
    }
  }

  void _paintDivider(Canvas canvas, Size size, PageFragment fragment) {
    final y = fragment.y + fragment.height / 2;
    canvas.drawLine(
      Offset(size.width * 0.3, y),
      Offset(size.width * 0.7, y),
      Paint()
        ..color = theme.secondary.withValues(alpha: 0.35)
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(_PagePainter old) =>
      old.slice != slice || old.theme != theme;
}
