import 'dart:math' as math;
import 'package:flutter/painting.dart';
import '../../domain/models/book_document.dart';
import '../../domain/models/locator.dart';
import '../layout/scroll_chapter.dart';
import '../layout/layout_options.dart';
import '../normalization/locator_mapper.dart';
import '../normalization/sentence_splitter.dart';
import 'selection_range.dart';

class ScrollRangeGeometry {
  const ScrollRangeGeometry(this.rects, {this.start, this.end,
    this.startHeight = 0, this.endHeight = 0});
  final List<Rect> rects;
  final Offset? start, end;
  final double startHeight, endHeight;
}

typedef ScrollLine = ({ScrollCell cell, int line, double y, LocatorMapper mapper});

/// 只遍历视口附近的行；命中与绘制使用同样的字距和 TextPainter。
class ScrollSelection {
  ScrollSelection({required this.chapters, required this.offset,
    required this.height, required this.options, required this.bookId,
    required this.version, required this.ordinals});
  final List<ScrollChapter> chapters;
  final double offset, height;
  final LayoutOptions options;
  final String bookId;
  final int version;
  final Map<String, int> ordinals;

  Iterable<ScrollLine> get lines sync* {
    var before = -offset;
    for (final chapter in chapters) {
      final mapper = LocatorMapper(bookId: bookId, contentVersion: version,
        chapterId: chapter.content.chapterId);
      if (chapter.cells.isEmpty) { before += chapter.height; continue; }
      var index = chapter.cellAt(-before);
      for (; index < chapter.cells.length; index++) {
        final cell = chapter.cells[index];
        var y = before + chapter.starts[index] + cell.gap;
        if (y > height) break;
        if (cell.table.isNotEmpty) {
          for (final fragment in cell.table) {
            final block = fragment.block;
            if (fragment.frameOnly || block.lines.isEmpty || block.isDecoration) continue;
            final top = before + chapter.starts[index] + fragment.y;
            if (top + fragment.height < 0 || top > height) continue;
            final source = chapter.content.blocks.firstWhere((b) => b.id == block.blockId);
            yield (cell: ScrollCell(source, block, 0, fragment.lineFrom, fragment.lineTo, 0),
              line: fragment.lineFrom, y: top, mapper: mapper);
          }
          continue;
        }
        if (y + cell.height < 0 || !cell.measured.isText || cell.measured.isDecoration) continue;
        for (var i = cell.from; i < cell.to; i++) {
          final h = cell.measured.lines[i].height;
          if (y + h >= 0 && y <= height) yield (cell: cell, line: i, y: y, mapper: mapper);
          y += h;
        }
      }
      before += chapter.height;
    }
  }

  TextPainter _painter(ScrollLine line) => line.cell.measured.createSingleLinePainter(
    lineIndex: line.line, textScaler: options.textScaler, color: const Color(0xff000000),
    letterSpacing: line.cell.measured.justifySpacingFor(line.line,
      maxWidth: line.cell.measured.layoutWidth ?? options.contentWidthFor(line.cell.measured.kind),
      textScaler: options.textScaler,
      enabled: line.cell.measured.tableId == null && line.cell.measured.kind == BlockKind.paragraph));
  int _start(ScrollLine line) => line.cell.offsetAt(line.line);
  int _end(ScrollLine line) => line.cell.offset + line.cell.measured.lines[line.line].end
      - line.cell.measured.displayPrefixLength;

  Locator? hit(Offset point, {bool exact = false}) {
    final visible = lines.where((l) => l.cell.measured.tableBounds == null ||
      (point.dx >= l.cell.measured.tableBounds!.left && point.dx <= l.cell.measured.tableBounds!.right)).toList()
      ..sort((a, b) => a.y.compareTo(b.y));
    if (visible.isEmpty) return null;
    final line = visible.firstWhere((l) => point.dy < l.y + l.cell.measured.lines[l.line].height,
      orElse: () => visible.last);
    final painter = _painter(line);
    if (exact && !painter.getBoxesForSelection(TextSelection(
        baseOffset: 0, extentOffset: painter.plainText.length)).any((box) =>
          box.toRect().shift(Offset(line.cell.measured.inset, line.y)).contains(point))) {
      painter.dispose();
      return null;
    }
    final local = painter.getPositionForOffset(Offset(point.dx - line.cell.measured.inset, 0)).offset;
    painter.dispose();
    return line.mapper.at(line.cell.block,
      (_start(line) + local).clamp(0, blockTextOf(line.cell.block).length));
  }

  SelectionRange? sentence(Offset point) {
    final locator = hit(point);
    if (locator == null) return null;
    final chapter = chapters.firstWhere((c) => c.content.chapterId == locator.chapterId);
    final block = chapter.content.blocks.firstWhere((b) => b.id == locator.blockId);
    final spans = splitSentences(blockTextOf(block));
    if (spans.isEmpty) return null;
    final span = spans[sentenceIndexAt(spans, locator.utf16Offset).clamp(0, spans.length - 1)];
    final mapper = LocatorMapper(bookId: bookId, contentVersion: version, chapterId: locator.chapterId);
    return SelectionRange(start: mapper.at(block, span.start), end: mapper.at(block, span.end));
  }

  ScrollRangeGeometry geometry(SelectionRange range) {
    final ordered = normalizeRange(range, chapterOrdinals: ordinals);
    final rects = <Rect>[];
    Offset? leading, trailing;
    double leadingHeight = 0, trailingHeight = 0;
    for (final line in lines) {
      final from = line.mapper.at(line.cell.block, _start(line));
      final to = line.mapper.at(line.cell.block, _end(line));
      int compare(Locator a, Locator b) => compareLocators(a, b, chapterOrdinals: ordinals);
      if (compare(to, ordered.start) <= 0 || compare(from, ordered.end) >= 0) continue;
      final start = compare(from, ordered.start) < 0 ? ordered.start.utf16Offset : _start(line);
      final end = compare(to, ordered.end) > 0 ? ordered.end.utf16Offset : _end(line);
      final painter = _painter(line);
      final boxes = painter.getBoxesForSelection(TextSelection(
        baseOffset: math.max(0, start - _start(line)), extentOffset: end - _start(line) + (line.cell.measured.lines[line.line].hyphenated && end == _end(line) ? 1 : 0)));
      painter.dispose();
      for (final box in boxes) {
        rects.add(Rect.fromLTWH(line.cell.measured.inset + box.left, line.y,
          box.right - box.left, line.cell.measured.lines[line.line].height));
      }
      if (boxes.isNotEmpty && compare(from, ordered.start) <= 0) {
        leading = Offset(rects[rects.length - boxes.length].left, rects.last.bottom);
        leadingHeight = line.cell.measured.lines[line.line].height;
      }
      if (boxes.isNotEmpty && compare(to, ordered.end) >= 0) {
        trailing = Offset(rects.last.right, rects.last.bottom);
        trailingHeight = line.cell.measured.lines[line.line].height;
      }
    }
    final reversed = compareLocators(range.start, range.end, chapterOrdinals: ordinals) > 0;
    return ScrollRangeGeometry(rects, start: reversed ? trailing : leading,
      end: reversed ? leading : trailing,
      startHeight: reversed ? trailingHeight : leadingHeight,
      endHeight: reversed ? leadingHeight : trailingHeight);
  }
}
