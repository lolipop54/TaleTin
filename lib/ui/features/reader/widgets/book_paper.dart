import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 纸边尺寸同时供正文留白、书签和动画裁剪使用，避免各层独立估算。
const double bookEdgeWidth = 12;
const double bookSpineWidth = 14;

/// WebView平移页的装饰随该页移动；颜色来自当前主题，没有固定浅色贴图。
String bookPaperSvg(Color paper) {
  String hex(Color c) => '#${c.toARGB32().toRadixString(16).substring(2)}';
  final base = hex(paper), dark = hex(Color.lerp(paper, Colors.black, .4)!);
  final light = hex(Color.lerp(paper, Colors.white, .22)!);
  return '<svg xmlns="http://www.w3.org/2000/svg" width="100%" height="100%">'
      '<defs><linearGradient id="spine"><stop stop-color="$dark"/>'
      '<stop offset=".65" stop-color="$light" stop-opacity=".2"/>'
      '<stop offset="1" stop-color="$base" stop-opacity="0"/></linearGradient></defs>'
      '<path d="M8 0 Q0 0 0 8 V100000 H14 V0 Z" fill="url(#spine)"/>'
      '<svg x="100%" width="12" height="100%" style="overflow:visible">'
      '${[for (var i = 0; i < 6; i++) '<rect x="${-12 + i * 2}" y="${i * .85}" width="2" height="100%" fill="${hex(Color.lerp(paper, Colors.black, .015 * (i + 1))!)}"/><path d="M${-12 + i * 2} ${i * .85} V100000" stroke="${hex(Color.lerp(paper, Colors.black, .26)!)}" stroke-width=".45"/>'].join()}'
      '</svg></svg>';
}

void paintBookPaper(
  Canvas canvas,
  Size size,
  Color paper, {
  bool edges = true,
  bool spread = false,
}) {
  if (size.isEmpty) return;
  final dark = Color.lerp(paper, Colors.black, .58)!;
  final light = Color.lerp(paper, Colors.white, .22)!;
  canvas.drawRect(Offset.zero & size, Paint()..color = dark);
  void stack(bool left) {
    canvas.save();
    if (left) {
      canvas.translate(size.width, 0);
      canvas.scale(-1, 1);
    }
    for (var i = 5; i >= 0; i--) {
      final x = size.width - bookEdgeWidth + i * 2;
      final inset = i * .85;
      canvas.drawRect(
        Rect.fromLTRB(x, inset, x + 2, size.height - inset),
        Paint()..color = Color.lerp(paper, Colors.black, .015 * (i + 1))!,
      );
      canvas.drawLine(
        Offset(x, inset),
        Offset(x, size.height - inset),
        Paint()
          ..color = Color.lerp(paper, Colors.black, .26)!
          ..strokeWidth = .45,
      );
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
  });
  final Color paper;
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
    paintBookPaper(canvas, size, paper, edges: edges, spread: spread);
    canvas.restore();
  }

  @override
  bool shouldRepaint(BookPaperPainter old) =>
      old.paper != paper ||
      old.edges != edges ||
      old.spread != spread ||
      old.decorationOnly != decorationOnly;
}
