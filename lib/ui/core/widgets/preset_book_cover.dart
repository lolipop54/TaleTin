import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../domain/models/book_cover_choice.dart';
import '../../../platform/channels/preset_fonts.dart';
import 'book_cover_resources.dart';

/// 图案和书名在同一固定画布等比缩放，缩略图不受系统字号影响。
class PresetBookCover extends StatelessWidget {
  const PresetBookCover({
    super.key,
    required this.preset,
    required this.title,
    required this.author,
  });
  final BookCoverPreset preset;
  final String title, author;

  @override
  Widget build(BuildContext context) => Semantics(
    label: '$title，${preset.label}封面',
    child: CustomPaint(
      painter: _PresetPainter(
        preset,
        title,
        author,
        DefaultTextStyle.of(context).style.fontFamily ?? 'sans-serif',
      ),
    ),
  );
}

class _PresetPainter extends CustomPainter {
  _PresetPainter(this.preset, this.title, this.author, this.fontFamily);
  final BookCoverPreset preset;
  final String title, author, fontFamily;
  static const ink = Color(0xff332c24);
  static const paper = Color(0xfff3e6c7);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 284, size.height / 400);
    final dark =
        preset == BookCoverPreset.stars || preset == BookCoverPreset.cloth;
    final text = dark ? paper : ink;
    if (BookCoverResources.images[preset] case final image?) {
      canvas.drawImageRect(
        image,
        Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
        const Rect.fromLTWH(0, 0, 284, 400),
        Paint()..filterQuality = FilterQuality.medium,
      );
    }
    if (preset == BookCoverPreset.martial) {
      _martial(canvas);
      _text(canvas, author, const Rect.fromLTWH(45, 355, 205, 25), paper, 12);
    } else {
      final centered =
          preset == BookCoverPreset.parchment ||
          preset == BookCoverPreset.cloth;
      final y = centered ? 115.0 : 34.0;
      _text(
        canvas,
        title,
        Rect.fromLTWH(30, y, 224, 105),
        text,
        29,
        maxLines: 3,
      );
      _text(
        canvas,
        author,
        Rect.fromLTWH(35, centered ? 250 : 355, 214, 30),
        text.withValues(alpha: .8),
        12,
      );
    }
    canvas.restore();
  }

  /// 参考传统蓝布线装书：左侧双白线，右侧通长旧纸题签。
  void _martial(Canvas canvas) {
    const label = Rect.fromLTWH(205, 23, 63, 318);
    // 先按文字实际尺寸排好整组，再把整组放在题签中心。
    // TextPainter 的 maxWidth 只是上限，不能拿它当实际字宽来定位。
    final chars = title.replaceAll(RegExp(r'\s+'), '').characters.toList();
    if (chars.isEmpty) return;
    final columns = chars.length <= 12 ? 1 : 2;
    final rows = (chars.length / columns).ceil();
    final inner = label.deflate(9);
    var fontSize = columns == 1 ? 48.0 : 24.0;
    final painters = [
      for (var col = 0; col < columns; col++)
        TextPainter(
          textDirection: TextDirection.ltr,
          textAlign: TextAlign.center,
          textHeightBehavior: const TextHeightBehavior(
            applyHeightToFirstAscent: false,
            applyHeightToLastDescent: false,
          ),
        ),
    ];
    var columnWidth = 0.0, height = 0.0, gap = 0.0;
    for (var pass = 0; pass < 3; pass++) {
      columnWidth = 0;
      height = 0;
      for (var col = 0; col < columns; col++) {
        final painter = painters[col];
        painter.text = TextSpan(
          text: chars.skip(col * rows).take(rows).join('\n'),
          style: TextStyle(
            fontFamily: PresetFonts.included
                ? 'gt-preset-lxgwzhenkai'
                : 'serif',
            fontSize: fontSize,
            height: 1.15,
            color: const Color(0xff14120b),
          ),
        );
        painter.layout();
        columnWidth = math.max(columnWidth, painter.width);
        height = math.max(height, painter.height);
      }
      gap = columns == 1 ? 0 : fontSize * .18;
      final width = columnWidth * columns + gap * (columns - 1);
      final scale = math.min(inner.width / width, inner.height / height);
      if (scale >= 1 || pass == 2) break;
      fontSize *= scale;
    }
    final width = columnWidth * columns + gap * (columns - 1);
    final right = inner.center.dx + width / 2;
    canvas.save();
    canvas.clipRect(inner);
    for (var col = 0; col < columns; col++) {
      final painter = painters[col];
      // 两列从右向左读；每列内部也按实际宽高居中，奇数字数不会偏到一边。
      painter.paint(
        canvas,
        Offset(
          right - col * (columnWidth + gap) - (columnWidth + painter.width) / 2,
          inner.center.dy - painter.height / 2,
        ),
      );
      painter.dispose();
    }
    canvas.restore();
  }

  void _text(
    Canvas canvas,
    String value,
    Rect rect,
    Color color,
    double size, {
    int maxLines = 2,
  }) {
    final painter = TextPainter(
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.center,
      maxLines: maxLines,
      ellipsis: '…',
    );
    do {
      painter.text = TextSpan(
        text: value,
        style: TextStyle(
          fontSize: size,
          fontFamily: fontFamily,
          color: color,
          height: 1.25,
          fontWeight: FontWeight.w500,
        ),
      );
      painter.layout(maxWidth: rect.width);
      if (painter.height <= rect.height && !painter.didExceedMaxLines) break;
      size -= 1;
    } while (size > 10);
    canvas.save();
    canvas.clipRect(rect);
    painter.paint(
      canvas,
      Offset(
        rect.left,
        rect.top + math.max(0, (rect.height - painter.height) / 2),
      ),
    );
    canvas.restore();
    painter.dispose();
  }

  @override
  bool shouldRepaint(_PresetPainter old) =>
      old.fontFamily != fontFamily ||
      old.preset != preset ||
      old.title != title ||
      old.author != author;
}
