import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import 'search_menu_appearance.dart';
import 'bookmark_ribbon.dart';
import 'book_paper.dart';

/// 信息属于各自书页。静态显示与折页缓存使用相同的位置和字形。
class PageInformation {
  const PageInformation({
    required this.chapter,
    required this.book,
    required this.progress,
    required this.clock,
    required this.battery,
    required this.inset,
    required this.bottomInset,
    required this.color,
    required this.scaler,
    required this.visible,
    this.searchMenu,
    this.fontFamily,
    this.bookmarked = false,
    this.bookEdges = false,
    this.spreadSide,
    this.spread = false,
    this.paper,
  });
  final String chapter, book, progress, clock;
  final int? battery;
  final double inset, bottomInset;
  final Color color;
  final TextScaler scaler;
  final bool visible;
  final SearchMenuAppearance? searchMenu;
  final String? fontFamily;
  final bool bookmarked;
  final bool bookEdges;

  /// null为单页；双页只在左上显示章名、左下显示进度、右下显示时间电量。
  final int? spreadSide;
  final bool spread;
  final Color? paper;

  /// 翻动页图包含的信息行；分钟、电量、书签或字号变化不能复用旧图。
  Object get paintingKey => (
    chapter,
    book,
    progress,
    clock,
    battery,
    inset,
    bottomInset,
    color,
    scaler.scale(11),
    scaler.scale(12),
    visible,
    fontFamily,
    bookmarked,
    searchMenu,
    bookEdges,
    spreadSide,
    spread,
    paper,
  );

  TextPainter _text(String text, double fontSize, double width) => TextPainter(
    text: TextSpan(
      text: text,
      style: GtText.caption(
        color,
        family: fontFamily,
      ).copyWith(fontSize: fontSize),
    ),
    textDirection: TextDirection.ltr,
    textScaler: scaler,
    maxLines: 1,
    ellipsis: '…',
  )..layout(maxWidth: math.max(0, width));

  double _height(double fontSize) {
    final p = _text('国', fontSize, double.infinity);
    final height = p.height;
    p.dispose();
    return height;
  }

  double get top => visible ? 16 + _height(12) : 0;
  double get bottom =>
      visible ? 12 + bottomInset + math.max(14, _height(11)) : 0;

  void paint(Canvas canvas, Size size, {bool paintMenu = true}) {
    if (paintMenu) searchMenu?.paint(canvas, size);
    if (bookmarked) {
      canvas.save();
      canvas.translate(
        size.width -
            bookmarkRibbonSize.width -
            bookmarkRibbonRight -
            (bookEdges ? bookEdgeWidth : 0),
        0,
      );
      const BookmarkRibbonPainter().paint(canvas, bookmarkRibbonSize);
      canvas.restore();
    }
    if (!visible) return;
    final width = math.max(0.0, size.width - 2 * inset);
    void label(
      String text,
      double fontSize,
      double x,
      double y,
      double maxWidth, [
      double align = 0,
    ]) {
      final p = _text(text, fontSize, maxWidth);
      p.paint(canvas, Offset(x - p.width * align, y));
      p.dispose();
    }

    if (spreadSide != 1) {
      label(
        chapter,
        12,
        inset,
        16,
        spread ? size.width / 2 - 2 * inset : width,
      );
    }
    final y = size.height - bottom;
    if (spreadSide != 1) label(progress, 11, inset, y, width / 3);
    if (spreadSide == 0) return;
    label(
      clock,
      11,
      spreadSide == 1 || spread ? size.width - inset - 58 : size.width / 2,
      y,
      width / 3,
      spreadSide == 1 || spread ? 1 : 0.5,
    );
    if (battery == null) return;
    label('$battery%', 11, size.width - inset - 18, y, width / 3 - 18, 1);
    // 五格随真实电量变化，直接绘制，翻页期间不异步加载图标。
    canvas.save();
    canvas.translate(
      size.width - inset - 14,
      y + (math.max(14, _height(11)) - 14) / 2,
    );
    canvas.scale(14 / 24);
    final pen = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.75
      ..strokeCap = StrokeCap.round;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(3, 7, 16, 10),
        const Radius.circular(2),
      ),
      pen,
    );
    canvas.drawLine(const Offset(21, 10), const Offset(21, 14), pen);
    final fill = Paint()..color = color;
    for (var i = 0; i < batterySegments(battery!); i++) {
      canvas.drawRect(Rect.fromLTWH(5 + i * 2.6, 9, 1.6, 6), fill);
    }
    canvas.restore();
  }

  /// 原书模式在独立 Shadow DOM 中显示，书籍 CSS 不会污染这些信息。
  Map<String, Object?> toHost(double start, double end) => {
    'bookmarkRibbon': bookmarkRibbonSvg,
    'bookmarkRibbonRight':
        bookmarkRibbonRight + (bookEdges ? bookEdgeWidth : 0),
    'bookEdges': bookEdges,
    'bookPaper': bookEdges && paper != null ? bookPaperSvg(paper!) : null,
    'spread': spread,
    'chapter': chapter,
    'book': book,
    'clock': clock,
    'battery': battery,
    'inset': inset,
    'top': top,
    'bottom': bottom,
    'bottomInset': bottomInset,
    'headerSize': scaler.scale(12),
    'footerSize': scaler.scale(11),
    'color': '#${color.toARGB32().toRadixString(16).substring(2)}',
    'visible': visible,
    'searchMenu': searchMenu?.svg,
    'returnProgress': searchMenu?.returnProgress ?? false,
    'start': start,
    'end': end,
    'progress': progress,
  };
}

/// 0% 空电池；其余每 20% 一格，1–20% 至少显示一格。
int batterySegments(int percent) => (percent.clamp(0, 100) + 19) ~/ 20;
