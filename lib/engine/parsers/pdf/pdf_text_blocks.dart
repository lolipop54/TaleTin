import 'dart:math' as math;

import 'package:pdfrx_engine/pdfrx_engine.dart';

/// 具有原页位置的正文候选。先按行复原文字，再按栏和段落排序。
class PdfTextBlock {
  PdfTextBlock(this.text, this.box);
  String text;
  List<double> box;
}

List<PdfTextBlock> pdfTextBlocks(PdfPageRawText? raw, PdfPage page) {
  return pdfTextBlocksFromGeometry(
    raw,
    page.width,
    page.height,
    page.rotation.index,
  );
}

/// 只接收文字、矩形与页面数值，允许后台整理，不传递PDFium对象。
List<PdfTextBlock> pdfTextBlocksFromGeometry(
  PdfPageRawText? raw,
  double width,
  double height,
  int rotation,
) {
  if (raw == null || raw.fullText.trim().isEmpty) return [];
  final lines = <PdfTextBlock>[];
  final text = StringBuffer();
  PdfRect? bounds;
  void flush() {
    final value = text.toString().replaceAll(RegExp(r'[\t ]+'), ' ').trim();
    final r = bounds;
    if (value.isNotEmpty && r != null) {
      final rotated = _rotate(r, width, height, rotation);
      lines.add(
        PdfTextBlock(value, [
          (rotated.left / width).clamp(0.0, 1.0),
          (1 - rotated.top / height).clamp(0.0, 1.0),
          (rotated.width / width).clamp(.0001, 1.0),
          (rotated.height / height).clamp(.0001, 1.0),
        ]),
      );
    }
    text.clear();
    bounds = null;
  }

  for (var i = 0; i < raw.fullText.length; i++) {
    final c = raw.fullText[i];
    if (c == '\n' || c == '\r') {
      flush();
      continue;
    }
    if (i < raw.charRects.length) {
      final r = raw.charRects[i];
      if (r.isNotEmpty) {
        // 某些PDF没有换行字符；垂直位置或远距离回到行首也构成新行。
        if (bounds != null &&
            text.isNotEmpty &&
            ((r.center.y - bounds!.center.y).abs() >
                    math.max(r.height, bounds!.height) * .7 ||
                r.left > bounds!.right + width * .12)) {
          flush();
        }
        bounds = bounds == null ? r : bounds!.merge(r);
      }
    }
    if (c != '\u0000' && c != '\ufffd') text.write(c);
  }
  flush();
  // 双栏先读完左栏再读右栏；贯穿两栏的标题仍位于其下两栏之前。
  final left = lines.where((l) => l.box[0] + l.box[2] < .54).length;
  final right = lines.where((l) => l.box[0] > .46).length;
  final columns = left >= 4 && right >= 4;
  lines.sort((a, b) {
    if (columns) {
      final ac = a.box[0] > .46 ? 1 : 0, bc = b.box[0] > .46 ? 1 : 0;
      if (ac != bc && a.box[2] < .55 && b.box[2] < .55) return ac - bc;
    }
    final y = a.box[1] - b.box[1];
    return y.abs() < .004 ? a.box[0].compareTo(b.box[0]) : y.sign.toInt();
  });
  final paragraphs = <PdfTextBlock>[];
  for (final line in lines) {
    final previous = paragraphs.lastOrNull;
    final gap = previous == null
        ? 1.0
        : line.box[1] - previous.box[1] - previous.box[3];
    final sameColumn =
        previous != null && (line.box[0] - previous.box[0]).abs() < .035;
    final end = previous?.text ?? '';
    if (previous != null &&
        sameColumn &&
        gap >= -.003 &&
        gap < line.box[3] * .65 &&
        !RegExp(r'[。！？!?：:]$').hasMatch(end) &&
        previous.box[2] > line.box[2] * .7) {
      final chinese =
          RegExp(r'[\u3400-\u9fff]$').hasMatch(end) ||
          RegExp(r'^[\u3400-\u9fff]').hasMatch(line.text);
      if (end.endsWith('-') && !chinese) {
        previous.text = end.substring(0, end.length - 1) + line.text;
      } else {
        previous.text += '${chinese ? '' : ' '}${line.text}';
      }
      final x = math.min(previous.box[0], line.box[0]);
      previous.box = [
        x,
        previous.box[1],
        math.max(previous.box[0] + previous.box[2], line.box[0] + line.box[2]) -
            x,
        line.box[1] + line.box[3] - previous.box[1],
      ];
    } else {
      paragraphs.add(line);
    }
  }
  return paragraphs;
}

// 与pdfrx_engine PdfRect.rotate相同的坐标变换；这里只使用页面快照中的数值。
PdfRect _rotate(PdfRect r, double pageWidth, double pageHeight, int rotation) {
  final swap = (rotation & 1) == 1;
  final width = swap ? pageHeight : pageWidth,
      height = swap ? pageWidth : pageHeight;
  return switch (rotation & 3) {
    0 => r,
    1 => PdfRect(r.bottom, width - r.left, r.top, width - r.right),
    2 => PdfRect(
      width - r.right,
      height - r.bottom,
      width - r.left,
      height - r.top,
    ),
    _ => PdfRect(height - r.top, r.right, height - r.bottom, r.left),
  };
}
