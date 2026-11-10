import 'dart:math' as math;

import 'package:flutter/painting.dart';

import 'measured_block.dart';
import 'formula_selection.dart';

/// 分页、滚动、选文和听书都使用这一份行内坐标；公式的上下结构不交给
/// 普通 TextPainter 重新排成一行，普通文字仍使用原来的字距与缩进规则。
extension LineTextGeometry on MeasuredBlock {
  TextPainter _geometryPainter(int line, TextScaler scaler, double width) =>
      createSingleLinePainter(
        lineIndex: line,
        textScaler: scaler,
        letterSpacing: justifySpacingFor(
          line,
          maxWidth: width,
          enabled: justifiesLine(line),
          textScaler: scaler,
        ),
      );
  TextPainter _geometrySegment(MeasuredSegment s, TextScaler scaler) =>
      createSegmentPainter(
        start: s.start,
        end: s.end,
        letterSpacing: s.letterSpacing,
        textScaler: scaler,
      );

  List<Rect> rangeRectsInLine(
    int index,
    int from,
    int to, {
    required TextScaler scaler,
    required double width,
    bool tight = false,
  }) {
    final line = lines[index], rects = <Rect>[];
    final left = inset + horizontalOffset(index, width);
    if (hasSegmentedText) {
      for (final s in line.segments) {
        final a = math.max(from, s.start), b = math.min(to, s.end);
        if (a >= b) continue;
        final p = _geometrySegment(s, scaler);
        for (final box in p.getBoxesForSelection(
          TextSelection(baseOffset: a - s.start, extentOffset: b - s.start),
        )) {
          if (box.right > box.left) {
            rects.add(
              Rect.fromLTWH(
                left + s.left + box.left,
                line.textTop + s.top + (tight ? box.top : 0),
                box.right - box.left,
                tight
                    ? box.bottom - box.top
                    : math.max(0, line.height - line.textTop - s.top),
              ),
            );
          }
        }
        p.dispose();
      }
      for (final object in inlineImagesInLines(index, index + 1)) {
        if (object.formula == null) {
          if (object.offset >= from && object.offset < to) {
            rects.add(
              Rect.fromLTWH(
                left + object.left,
                0,
                object.size.width,
                line.height,
              ),
            );
          }
        } else {
          rects.addAll(
            object
                .selectedRects(from, to)
                .map((r) => r.shift(Offset(left + object.left, object.top))),
          );
        }
      }
    } else if (to > from) {
      final p = _geometryPainter(index, scaler, width);
      for (final b in p.getBoxesForSelection(
        TextSelection(
          baseOffset: from - line.start,
          extentOffset:
              to - line.start + (line.hyphenated && to == line.end ? 1 : 0),
        ),
      )) {
        if (b.right > b.left) {
          rects.add(
            Rect.fromLTWH(
              left + b.left,
              tight ? b.top : 0,
              b.right - b.left,
              tight ? b.bottom - b.top : line.height,
            ),
          );
        }
      }
      p.dispose();
    }
    return rects;
  }

  int offsetAtInLine(
    int index,
    Offset point, {
    required TextScaler scaler,
    required double width,
  }) {
    final line = lines[index];
    if (line.start == line.end) return line.start;
    final x = point.dx - inset - horizontalOffset(index, width);
    if (hasSegmentedText) {
      for (final object in inlineImagesInLines(index, index + 1)) {
        if (x >= object.left && x <= object.left + object.size.width) {
          return object
              .offsetAt(Offset(x - object.left, point.dy - object.top))
              .clamp(line.start, line.end);
        }
      }
      final s = segmentAtX(index, x);
      if (s == null) return line.start;
      final p = _geometrySegment(s.segment, scaler);
      final offset = p
          .getPositionForOffset(Offset(s.dx, line.height / 2))
          .offset;
      p.dispose();
      return (s.segment.start + offset).clamp(line.start, line.end);
    }
    final p = _geometryPainter(index, scaler, width);
    final offset = p.getPositionForOffset(Offset(x, line.height / 2)).offset;
    p.dispose();
    return (line.start + offset).clamp(line.start, line.end);
  }

  Rect? caretRectInLine(
    int index,
    int offset,
    bool atEnd, {
    required TextScaler scaler,
    required double width,
  }) {
    final line = lines[index], left = inset + horizontalOffset(index, width);
    if (hasSegmentedText) {
      for (final object in inlineImagesInLines(index, index + 1)) {
        final end = object.formula?.end ?? object.offset;
        if (object.offset <= offset && offset <= end) {
          return object
              .caretRect(offset, atEnd)
              .shift(Offset(left + object.left, object.top));
        }
      }
      final s = segmentAtOffset(index, offset);
      if (s == null) return null;
      final p = _geometrySegment(s, scaler);
      final x = p
          .getOffsetForCaret(
            TextPosition(offset: (offset - s.start).clamp(0, s.end - s.start)),
            Rect.zero,
          )
          .dx;
      p.dispose();
      return Rect.fromLTWH(left + s.left + x, 0, 0, line.height);
    }
    final p = _geometryPainter(index, scaler, width);
    final x = p
        .getOffsetForCaret(TextPosition(offset: offset - line.start), Rect.zero)
        .dx;
    p.dispose();
    return Rect.fromLTWH(left + x, 0, 0, line.height);
  }
}
