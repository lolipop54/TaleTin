import 'dart:math' as math;

import 'package:flutter/painting.dart';

import '../../../../domain/models/locator.dart';
import '../../../../engine/layout/chapter_layout.dart';
import '../../../../engine/layout/measured_block.dart';
import '../../../../engine/layout/line_text_geometry.dart';
import '../../../../engine/selection/scroll_selection.dart';

/// 在排版结果里找到某个文字位置对应的链接。
///
/// [locator] 的偏移是标准化正文坐标（不含首行缩进前缀），这里换算成显示坐标
/// 后找所在的 run。返回 null 表示这个位置不是链接。
({String link, bool footnote})? linkAtLocator(
  ChapterLayout layout,
  Locator locator,
) {
  final block = layout.blocks
      .where((b) => b.blockId == locator.blockId)
      .firstOrNull;
  return block == null ? null : linkAtMeasured(block, locator.utf16Offset);
}

/// 同上，直接给测量块（连续滚动模式没有 ChapterLayout）。
({String link, bool footnote})? linkAtMeasured(
  MeasuredBlock block,
  int normalizedOffset,
) {
  if (block.runs.isEmpty) return null;
  final display = normalizedOffset + block.displayPrefixLength;
  var cursor = 0;
  for (final run in block.runs) {
    final end = cursor + run.text.length;
    if (display >= cursor && display < end) {
      // 命中普通正文就直接结束，不能继续回退到段末的脚注链接。
      return run.link == null
          ? null
          : (link: run.link!, footnote: run.footnote);
    }
    cursor = end;
  }
  // 光标恰好在块末时仍可查询最后一个片段；屏幕点击另按标记矩形判断。
  final last = block.runs.last;
  return display == cursor && last.link != null
      ? (link: last.link!, footnote: last.footnote)
      : null;
}

const _smallMarkerSize = 24.0;
const _hitPadding = 4.0;
typedef ReaderLinkHit = ({
  String? link,
  bool footnote,
  bool image,
  Offset anchor,
});
typedef _Line = ({MeasuredBlock block, int index, double y, double width});

/// 链接、图片和普通文字均使用绘制坐标。仅在小脚注周围找不到直接命中的内容时补点。
class _LinkProbe {
  _LinkProbe(this.point, this.scaler, this.padding);
  final Offset point;
  final TextScaler scaler;
  final double padding;
  ReaderLinkHit? exact, nearest;
  bool overImage = false;
  double distance = double.infinity;

  void consider(
    Rect rect,
    String? link, {
    required bool footnote,
    required bool image,
    bool hasNoteText = false,
    bool small = true,
  }) {
    if (rect.isEmpty) return;
    if (rect.contains(point)) {
      if (image) overImage = true;
      if (link != null || hasNoteText) {
        exact ??= (
          link: link,
          footnote: footnote,
          image: image,
          anchor: image ? rect.center : point,
        );
      }
      return;
    }
    if ((link == null && !hasNoteText) ||
        !footnote ||
        !small ||
        rect.longestSide > _smallMarkerSize ||
        !rect.inflate(padding).contains(point)) {
      return;
    }
    final closest = Offset(
      point.dx.clamp(rect.left, rect.right),
      point.dy.clamp(rect.top, rect.bottom),
    );
    final d = (point - closest).distanceSquared;
    if (d >= distance) return;
    distance = d;
    nearest = (
      link: link,
      footnote: true,
      image: image,
      anchor: image ? rect.center : closest,
    );
  }

  Iterable<({Rect rect, String? link, bool footnote, bool small})> _ranges(
    _Line row, {
    required bool links,
  }) sync* {
    final block = row.block, line = block.lines[row.index];
    var cursor = 0, index = 0;
    while (index < block.runs.length && cursor < line.end) {
      final first = block.runs[index];
      final groupStart = cursor;
      final boxes = <Rect>[];
      // 同一链接可因粗体、颜色或上下标拆成多段，以整个标记判断大小。
      do {
        final run = block.runs[index++];
        final start = cursor;
        cursor += run.text.length;
        final from = math.max(start, line.start),
            to = math.min(cursor, line.end);
        if ((run.link != null) != links || from >= to) continue;
        final text = run.text.substring(from - start, to - start);
        for (final part in (links ? _linkText : _bodyText).allMatches(text)) {
          final a = from + part.start, b = from + part.end;
          final rects = run.isScript
              ? block.scriptRectsInLine(
                  row.index,
                  a,
                  b,
                  scaler: scaler,
                  width: row.width,
                )
              : block.rangeRectsInLine(
                  row.index,
                  a,
                  b,
                  scaler: scaler,
                  width: row.width,
                  tight: true,
                  includeInlineImages: false,
                );
          boxes.addAll(rects);
        }
      } while (index < block.runs.length &&
          block.runs[index].link == first.link &&
          block.runs[index].footnote == first.footnote);
      if (boxes.isEmpty) continue;
      final small =
          first.footnote &&
          groupStart >= line.start &&
          cursor <= line.end &&
          boxes.reduce((a, b) => a.expandToInclude(b)).longestSide <=
              _smallMarkerSize;
      for (final rect in boxes) {
        yield (
          rect: rect.shift(Offset(0, row.y)),
          link: first.link,
          footnote: first.footnote,
          small: small,
        );
      }
    }
  }

  ReaderLinkHit? resolve(Iterable<_Line> lines) {
    if (exact != null) return exact;
    final nearby = <_Line>[];
    for (final row in lines) {
      final h = row.block.lines[row.index].height;
      // 上下标可超出行带；预筛只用于省掉远处行的文字测量。
      if ((point.dy - row.y).abs() > h * 2 + padding && !row.block.hasScript) {
        continue;
      }
      nearby.add(row);
      for (final run in _ranges(row, links: true)) {
        consider(
          run.rect,
          run.link,
          footnote: run.footnote,
          image: false,
          small: run.small,
        );
      }
      if (exact != null) return exact;
    }
    if (nearest == null || overImage) return null;
    for (final row in nearby) {
      if (_ranges(row, links: false).any((r) => r.rect.contains(point))) {
        return null;
      }
    }
    return nearest;
  }
}

final _linkText = RegExp(r'[^\uFFFC]+');
final _bodyText = RegExp(r'[^\s\uFFFC]+');

ReaderLinkHit? readerPageHit(
  ChapterLayout layout,
  int index,
  Offset point, {
  double padding = _hitPadding,
}) {
  final page = layout.page(index);
  if (page == null) return null;
  final probe = _LinkProbe(point, layout.options.textScaler, padding);
  final width = layout.contentSize.width;
  final lines = <_Line>[];
  for (final f in page.fragments) {
    if (f.frameOnly) continue;
    if (f.block.hasInlineImages) {
      for (final item in f.positionedInlineImages) {
        probe.consider(
          item.rect,
          item.image.noteLink,
          hasNoteText: item.image.altIsFootnote,
          footnote: true,
          image: true,
        );
      }
    }
    final rect = f.imageRectIn(width);
    if (rect != null) {
      probe.consider(
        rect,
        f.block.noteLink,
        hasNoteText: f.block.altIsFootnote,
        footnote: true,
        image: true,
      );
    }
    var y = f.y + f.block.textTopOf(f.lineFrom);
    for (var i = f.lineFrom; i < f.lineTo; i++) {
      lines.add((
        block: f.block,
        index: i,
        y: y,
        width: f.block.layoutWidth ?? width,
      ));
      y += f.block.lines[i].height;
    }
  }
  return probe.resolve(lines);
}

ReaderLinkHit? readerScrollHit(ScrollSelection model, Offset point) {
  final width = model.options.contentWidth;
  final probe = _LinkProbe(point, model.options.textScaler, _hitPadding);
  var before = -model.offset;
  for (final chapter in model.chapters) {
    final y = point.dy - before;
    if (chapter.cells.isNotEmpty &&
        y >= -_hitPadding &&
        y <= chapter.height + _hitPadding) {
      // 脚注可位于两格接缝，4dp 内的相邻格也参与比较。
      final last = chapter.cellAt(y + _hitPadding);
      for (var i = chapter.cellAt(y - _hitPadding); i <= last; i++) {
        final cell = chapter.cells[i],
            origin = Offset(0, before + chapter.starts[i]);
        for (final item in cell.positionedInlineImages) {
          probe.consider(
            item.rect.shift(origin),
            item.image.noteLink,
            hasNoteText: item.image.altIsFootnote,
            footnote: true,
            image: true,
          );
        }
        for (final item in cell.positionedImages(width)) {
          probe.consider(
            item.rect.shift(origin),
            item.block.noteLink,
            hasNoteText: item.block.altIsFootnote,
            footnote: true,
            image: true,
          );
        }
      }
    }
    before += chapter.height;
  }
  return probe.resolve(
    model.lines.map(
      (l) => (
        block: l.cell.measured,
        index: l.line,
        y: l.y,
        width: l.cell.measured.layoutWidth ?? width,
      ),
    ),
  );
}

typedef ReaderLinkTarget = ({String link, bool footnote});
ReaderLinkTarget? _link(ReaderLinkHit? hit, bool footnotesOnly) =>
    hit == null || hit.link == null || (footnotesOnly && !hit.footnote)
    ? null
    : (link: hit.link!, footnote: hit.footnote);

ReaderLinkTarget? readerLinkAtMeasuredPoint(
  MeasuredBlock block,
  int lineIndex,
  Offset point, {
  required TextScaler scaler,
  required double width,
  double tolerance = 0,
  bool footnotesOnly = false,
}) => _link(
  _LinkProbe(
    point,
    scaler,
    tolerance,
  ).resolve([(block: block, index: lineIndex, y: 0.0, width: width)]),
  footnotesOnly,
);

ReaderLinkTarget? readerLinkNearPoint(
  ChapterLayout layout,
  int index,
  Offset point, {
  double tolerance = _hitPadding,
  bool footnotesOnly = false,
}) => _link(
  readerPageHit(layout, index, point, padding: tolerance),
  footnotesOnly,
);

bool readerPageLinkAt(ChapterLayout layout, int index, Offset point) =>
    readerPageHit(layout, index, point) != null;

ReaderLinkTarget? readerLinkAtScrollPoint(
  ScrollSelection selection,
  Offset point, {
  bool footnotesOnly = false,
}) => _link(readerScrollHit(selection, point), footnotesOnly);

ReaderLinkTarget? footnoteAtMeasuredPoint(
  MeasuredBlock block,
  int lineIndex,
  Offset point, {
  required TextScaler scaler,
  required double width,
  double tolerance = 0,
}) => readerLinkAtMeasuredPoint(
  block,
  lineIndex,
  point,
  scaler: scaler,
  width: width,
  tolerance: tolerance,
  footnotesOnly: true,
);

ReaderLinkTarget? footnoteNearPoint(
  ChapterLayout layout,
  int index,
  Offset point, {
  double tolerance = _hitPadding,
}) => readerLinkNearPoint(
  layout,
  index,
  point,
  tolerance: tolerance,
  footnotesOnly: true,
);

ReaderLinkTarget? footnoteAtScrollPoint(ScrollSelection selection, Offset point) =>
    readerLinkAtScrollPoint(selection, point, footnotesOnly: true);
