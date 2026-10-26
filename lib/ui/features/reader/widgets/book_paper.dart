import 'dart:math' as math;
import 'dart:ui' as ui;

import '../../../core/theme/reading_background_texture.dart';
export '../../../core/theme/reading_background_texture.dart'
    show paintReadingBackground, ReadingBackgroundPainter;

import 'package:flutter/material.dart';

/// 纸边尺寸同时供正文留白、书签和动画裁剪使用，避免各层独立估算。
const double bookEdgeWidth = 12;
const double bookSpineWidth = 14;

/// 书边页叠：6 层，每层 2dp；越靠外越向里缩，形成一眼能看出的阶梯。
const int bookEdgeLayers = 6;
const double bookEdgeLayerWidth = bookEdgeWidth / bookEdgeLayers;
const double bookEdgeLayerInset = 1.2;
const double bookEdgeSeamWidth = .8;
const double bookEdgeHighlightWidth = .35;

Color _bookEdgeFace(Color paper, int layer) =>
    Color.lerp(paper, Colors.black, .025 + layer * .04)!;

Color _bookEdgeTint(int layer) =>
    Colors.black.withValues(alpha: .025 + layer * .016);

/// WebView平移页的装饰随该页移动；颜色来自当前主题，没有固定浅色贴图。
String bookPaperSvg(Color paper, {bool hasBackgroundImage = false}) {
  String hex(Color c) => '#${c.toARGB32().toRadixString(16).substring(2)}';
  final base = hex(paper), dark = hex(Color.lerp(paper, Colors.black, .4)!);
  final light = hex(Color.lerp(paper, Colors.white, .22)!);
  String edge(int layer) {
    final x = -bookEdgeWidth + layer * bookEdgeLayerWidth;
    final y = layer * bookEdgeLayerInset;
    // 有背景图时页叠只叠一层很轻的明暗，让图片能透出来；没有背景图时
    // 用不透明纸色，和 Flutter 的页叠保持同一套明暗。
    final face = hasBackgroundImage
        ? '<rect x="$x" y="$y" width="$bookEdgeLayerWidth" height="100%" '
              'fill="${layer.isEven ? '#FFFFFF' : '#000000'}" fill-opacity=".055"/>'
        : '<rect x="$x" y="$y" width="$bookEdgeLayerWidth" height="100%" '
              'fill="${hex(_bookEdgeFace(paper, layer))}"/>';
    return '$face'
        '<path d="M$x $y V100000" stroke="#000000" stroke-opacity=".44" '
        'stroke-width="$bookEdgeSeamWidth"/>'
        '<path d="M${x + bookEdgeSeamWidth} $y V100000" stroke="#FFFFFF" '
        'stroke-opacity=".30" stroke-width="$bookEdgeHighlightWidth"/>';
  }

  return '<svg xmlns="http://www.w3.org/2000/svg" width="100%" height="100%">'
      '<defs><linearGradient id="spine"><stop stop-color="$dark"/>'
      '<stop offset=".65" stop-color="$light" stop-opacity=".2"/>'
      '<stop offset="1" stop-color="$base" stop-opacity="0"/></linearGradient></defs>'
      '<path d="M8 0 Q0 0 0 8 V100000 H14 V0 Z" fill="url(#spine)"/>'
      '<svg x="100%" width="$bookEdgeWidth" height="100%" style="overflow:visible">'
      '${[for (var i = bookEdgeLayers - 1; i >= 0; i--) edge(i)].join()}'
      '</svg></svg>';
}

void paintBookPaper(
  Canvas canvas,
  Size size,
  Color paper, {
  bool edges = true,
  bool spread = false,
  ui.Image? backgroundImage,
}) {
  if (size.isEmpty) return;
  final dark = Color.lerp(paper, Colors.black, .58)!;
  final light = Color.lerp(paper, Colors.white, .22)!;
  // 没有背景图时用深色垫出页与页之间的缝；有背景图时保留纸面图片，
  // 只在书边区补一次图片，页叠的半透明明暗不会把书边盖成纯色方块。
  if (backgroundImage != null && edges) {
    final path = Path()
      ..addRect(
        Rect.fromLTWH(
          size.width - bookEdgeWidth,
          0,
          bookEdgeWidth,
          size.height,
        ),
      );
    if (spread) {
      path.addRect(Rect.fromLTWH(0, 0, bookEdgeWidth, size.height));
    }
    canvas.save();
    canvas.clipPath(path);
    paintReadingBackground(canvas, size, paper, backgroundImage);
    canvas.restore();
  } else if (backgroundImage == null) {
    canvas.drawRect(Offset.zero & size, Paint()..color = dark);
  }
  void stack(bool left) {
    canvas.save();
    if (left) {
      canvas.translate(size.width, 0);
      canvas.scale(-1, 1);
    }
    // 从最外层画到最内层；每层向内缩一点，形成阶梯状页叠。
    for (var i = bookEdgeLayers - 1; i >= 0; i--) {
      final x = size.width - bookEdgeWidth + i * bookEdgeLayerWidth;
      final inset = i * bookEdgeLayerInset;
      final rect = Rect.fromLTRB(
        x,
        inset,
        x + bookEdgeLayerWidth,
        size.height - inset,
      );
      canvas.save();
      canvas.clipRect(rect);
      if (backgroundImage == null) {
        canvas.drawRect(rect, Paint()..color = _bookEdgeFace(paper, i));
      } else {
        // 每层是一张独立的纸：先取自己在整页背景图里的那一条，再压一层
        // 很轻的阴影。取图片而不是铺半透明纸色，背景图不会被洗白。
        final visualLeft = left ? size.width - rect.right : rect.left;
        canvas.drawImageRect(
          backgroundImage,
          Rect.fromLTWH(
            backgroundImage.width * visualLeft / size.width,
            backgroundImage.height * rect.top / size.height,
            backgroundImage.width * rect.width / size.width,
            backgroundImage.height * rect.height / size.height,
          ),
          rect,
          Paint()..filterQuality = FilterQuality.low,
        );
        canvas.drawRect(rect, Paint()..color = _bookEdgeTint(i));
      }
      // 页与页之间的暗缝和紧挨着的纸白高光，远看也能分出层。
      canvas.drawLine(
        Offset(x, inset),
        Offset(x, size.height - inset),
        Paint()
          ..color = Colors.black.withValues(alpha: .44)
          ..strokeWidth = bookEdgeSeamWidth,
      );
      canvas.drawLine(
        Offset(x + bookEdgeSeamWidth, inset),
        Offset(x + bookEdgeSeamWidth, size.height - inset),
        Paint()
          ..color = Colors.white.withValues(alpha: .30)
          ..strokeWidth = bookEdgeHighlightWidth,
      );
      canvas.restore();
    }
    canvas.restore();
  }

  if (edges) {
    stack(false);
    if (spread) stack(true);
  }
  final left = edges && spread ? bookEdgeWidth : 0.0;
  final right = size.width - (edges ? bookEdgeWidth : 0);
  final mid = size.width / 2;
  // 曲线仅作用在装订处，正文纸面的外角保持平直。
  Path leaf(double l, double r, bool spineRight) {
    const bend = 8.0;
    return spineRight
        ? (Path()
            ..moveTo(l, 0)
            ..lineTo(r - bend, 0)
            ..quadraticBezierTo(r, 0, r, bend)
            ..lineTo(r, size.height - bend)
            ..quadraticBezierTo(r, size.height, r - bend, size.height)
            ..lineTo(l, size.height)
            ..close())
        : (Path()
            ..moveTo(l + bend, 0)
            ..lineTo(r, 0)
            ..lineTo(r, size.height)
            ..lineTo(l + bend, size.height)
            ..quadraticBezierTo(l, size.height, l, size.height - bend)
            ..lineTo(l, bend)
            ..quadraticBezierTo(l, 0, l + bend, 0)
            ..close());
  }

  void sheet(double l, double r, bool spineRight) {
    final path = leaf(l, r, spineRight);
    canvas.drawPath(path, Paint()..color = paper);
    final w = math.min(bookSpineWidth, (r - l) / 6);
    final rect = Rect.fromLTWH(spineRight ? r - w : l, 0, w, size.height);
    canvas.save();
    canvas.clipPath(path);
    if (backgroundImage != null) {
      paintReadingBackground(canvas, size, paper, backgroundImage);
    }
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          colors: spineRight
              ? [paper.withValues(alpha: 0), dark.withValues(alpha: .5)]
              : [
                  dark.withValues(alpha: .5),
                  light.withValues(alpha: .15),
                  paper.withValues(alpha: 0),
                ],
          stops: spineRight ? null : const [0, .65, 1],
        ).createShader(rect),
    );
    canvas.restore();
  }

  if (spread) {
    sheet(left, mid, true);
    sheet(mid, right, false);
  } else {
    sheet(left, right, false);
  }
}

class BookPaperPainter extends CustomPainter {
  const BookPaperPainter(
    this.paper, {
    this.edges = true,
    this.spread = false,
    this.decorationOnly = false,
    this.backgroundImage,
  });
  final Color paper;
  final ui.Image? backgroundImage;
  final bool edges, spread, decorationOnly;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    if (decorationOnly) {
      final path = Path()
        ..addRect(
          Rect.fromLTWH(
            0,
            0,
            spread ? bookEdgeWidth : bookSpineWidth,
            size.height,
          ),
        )
        ..addRect(
          Rect.fromLTWH(
            size.width - bookEdgeWidth,
            0,
            bookEdgeWidth,
            size.height,
          ),
        );
      if (spread) {
        path.addRect(
          Rect.fromLTWH(
            size.width / 2 - bookSpineWidth,
            0,
            bookSpineWidth * 2,
            size.height,
          ),
        );
      }
      canvas.clipPath(path);
    }
    paintBookPaper(
      canvas,
      size,
      paper,
      edges: edges,
      spread: spread,
      backgroundImage: backgroundImage,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(BookPaperPainter old) =>
      old.paper != paper ||
      old.backgroundImage != backgroundImage ||
      old.edges != edges ||
      old.spread != spread ||
      old.decorationOnly != decorationOnly;
}
