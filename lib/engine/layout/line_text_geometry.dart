import 'dart:math' as math;

import 'package:flutter/painting.dart';

import '../selection/initial_text_range.dart';
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

  /// 只在负边距导致行带相交时使用。一个普通行（或混排中的文字段）只塑形一次，
  /// 复用同一个 painter 查询各段可读文字，避免把缩进、词间空白或插图视为文字。
  List<Rect> readableRectsInLine(int index, TextScaler scaler, double width) {
    final line = lines[index], boxes = <Rect>[];
    final left = inset + horizontalOffset(index, width);
    void collect(
      int from,
      int to,
      double x,
      double y,
      TextPainter Function() make,
    ) {
      final start = math.max(from, displayPrefixLength);
      if (start >= to) return;
      TextPainter? painter;
      for (final word in _visibleWords.allMatches(text.substring(start, to))) {
        painter ??= make();
        for (final box in painter.getBoxesForSelection(
          TextSelection(
            baseOffset: start - from + word.start,
            extentOffset: start - from + word.end,
          ),
        )) {
          if (box.right > box.left) boxes.add(box.toRect().shift(Offset(x, y)));
        }
      }
      painter?.dispose();
    }

    if (hasSegmentedText) {
      for (final seg in line.segments) {
        collect(
          seg.start,
          seg.end,
          left + seg.left,
          line.textTop + seg.top,
          () => _geometrySegment(seg, scaler),
        );
      }
    } else {
      collect(
        line.start,
        line.end,
        left,
        0,
        () => _geometryPainter(index, scaler, width),
      );
    }
    return boxes;
  }

  List<Rect> rangeRectsInLine(
    int index,
    int from,
    int to, {
    required TextScaler scaler,
    required double width,
    bool tight = false,
    bool includeInlineImages = true,
  }) {
    final line = lines[index], rects = <Rect>[];
    final useGlyphHeight = tight || line.stacked;
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
                line.textTop + s.top + (useGlyphHeight ? box.top : 0),
                box.right - box.left,
                useGlyphHeight
                    ? box.bottom - box.top
                    : math.max(0, line.height - line.textTop - s.top),
              ),
            );
          }
        }
        p.dispose();
      }
      // 脚注命中会按绘制位置单独检查图片，不能把图片旁边整行高度当成正文。
      if (!includeInlineImages) return rects;
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
      final s = line.stacked
          ? _stackedSegment(index, x, point.dy, scaler)
          : segmentAtX(index, x);
      if (s == null) return line.start;
      final p = _geometrySegment(s.segment, scaler);
      final offset = p
          .getPositionForOffset(
            Offset(
              s.dx,
              line.stacked
                  ? point.dy - line.textTop - s.segment.top
                  : line.height / 2,
            ),
          )
          .offset;
      p.dispose();
      return (s.segment.start + offset).clamp(line.start, line.end);
    }
    final p = _geometryPainter(index, scaler, width);
    final offset = p.getPositionForOffset(Offset(x, line.height / 2)).offset;
    p.dispose();
    return (line.start + offset).clamp(line.start, line.end);
  }

  /// 长按命中字形，拖手柄才用最近的插入点。否则按住一个字的右半边，
  /// 插入点会落在这个字之后，起选时就会选成后一个字。
  Future<({int start, int end})?> initialSelectionInLine(
    int index,
    Offset point, {
    required TextScaler scaler,
    required double width,
    required String source,
    int sourceOffset = 0,
  }) async {
    final line = lines[index];
    if (point.dy < 0 || point.dy >= line.height) return null;
    final x = point.dx - inset - horizontalOffset(index, width);
    final origin = sourceOffset - displayPrefixLength;

    Future<({int start, int end})?> textRange(
      TextPainter painter,
      double dx,
      int start,
    ) async {
      final glyph = painter.getClosestGlyphForOffset(Offset(dx, 0));
      final bounds = glyph?.graphemeClusterLayoutBounds;
      final hit =
          bounds != null &&
          dx >= math.max(0, bounds.left) &&
          dx < math.min(painter.width, bounds.right);
      painter.dispose();
      if (!hit) return null;
      final display = start + glyph!.graphemeClusterCodeUnitRange.start;
      if (display < displayPrefixLength || display >= line.end) return null;
      return initialTextRange(source, origin + display);
    }

    if (hasSegmentedText) {
      for (final object in inlineImagesInLines(index, index + 1)) {
        if ((Offset(object.left, object.top) & object.size).contains(
          Offset(x, point.dy),
        )) {
          return (
            start: origin + object.offset,
            end: origin + (object.formula?.end ?? object.offset + 1),
          );
        }
      }
      final hit = line.stacked
          ? _stackedSegment(index, x, point.dy, scaler, strict: true)
          : segmentAtX(index, x);
      if (hit == null) return null;
      final segment = hit.segment;
      return textRange(
        _geometrySegment(segment, scaler),
        x - segment.left,
        segment.start,
      );
    }
    return textRange(_geometryPainter(index, scaler, width), x, line.start);
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
      final height = line.stacked ? p.height : line.height;
      p.dispose();
      return Rect.fromLTWH(
        left + s.left + x,
        line.stacked ? line.textTop + s.top : 0,
        0,
        height,
      );
    }
    final p = _geometryPainter(index, scaler, width);
    final x = p
        .getOffsetForCaret(TextPosition(offset: offset - line.start), Rect.zero)
        .dx;
    p.dispose();
    return Rect.fromLTWH(left + x, 0, 0, line.height);
  }

  /// 同一行带可含上下两段。先按实际字形所在的高度找，再算左右位置。
  ({MeasuredSegment segment, double dx})? _stackedSegment(
    int index,
    double x,
    double y,
    TextScaler scaler, {
    bool strict = false,
  }) {
    final line = lines[index];
    MeasuredSegment? nearest;
    var bestVertical = double.infinity, bestHorizontal = double.infinity;
    for (final segment in line.segments) {
      final painter = _geometrySegment(segment, scaler);
      final top = line.textTop + segment.top;
      final bottom = top + painter.height;
      painter.dispose();
      final vertical = math.max(0.0, math.max(top - y, y - bottom));
      final horizontal = math.max(
        0.0,
        math.max(segment.left - x, x - segment.left - segment.width),
      );
      if (strict && (vertical > 0 || horizontal > 0)) continue;
      if (vertical < bestVertical ||
          (vertical == bestVertical && horizontal < bestHorizontal)) {
        nearest = segment;
        bestVertical = vertical;
        bestHorizontal = horizontal;
      }
    }
    return nearest == null ? null : (segment: nearest, dx: x - nearest.left);
  }
}

final _visibleWords = RegExp(r'[^\s\uFFFC]+');
