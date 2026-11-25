part of 'block_measure.dart';

extension FloatTextMeasurement on BlockMeasurer {
  /// 同一段中只在能使用的左右边界变化时重新断行。已经量好的行原样保留，
  /// 例如窄行末尾的标点、两端对齐字距和行内图片仍属于原来的字符位置。
  (MeasuredBlock, double, double, double) wrapBesideFloats(
    ContentBlock block,
    MeasuredBlock natural,
    List<FloatFootprint> floats, {
    required double parentLeft,
    required double parentWidth,
    required double paragraphTop,
    required bool withIndent,
  }) {
    final parts = <MeasuredBlock>[], limits = <MeasuredBlock, int>{};
    List<({double left, double right})>? intervals;
    var offset = 0, y = paragraphTop, start = paragraphTop, gap = 0.0;
    var minLeft = parentWidth, maxRight = 0.0;
    var firstHeight = 0.0;
    final index = displayTree?.blockIndexById[block.id];
    final clear = displayTree?.clearBreaks[index];
    double clearBottom(int start, double current) {
      if (clear == null) return current;
      final side = clear[start] ?? (start > 0 ? clear[start - 1] : null);
      if (side == null) return current;
      for (final item in floats) {
        if (side == ClearSpec.both ||
            (item.right ? side == ClearSpec.right : side == ClearSpec.left)) {
          current = math.max(current, item.bounds.bottom);
        }
      }
      return current;
    }

    while (true) {
      final cleared = clearBottom(offset, y);
      if (cleared > y) {
        if (parts.isEmpty) {
          start = cleared;
        } else {
          gap += cleared - y;
        }
        y = cleared;
      }
      final leading = offset == 0 ? natural.bodyTop : 0.0;
      final band = floatLineInterval(
        floats,
        parentWidth,
        y + leading,
        height: firstHeight,
      );
      final left = parentLeft + band.left, right = parentLeft + band.right;
      final available =
          math.min(natural.inset + natural.layoutWidth!, right) -
          math.max(natural.inset, left);
      final beside = band.nextBottom.isFinite;
      // 只有连下一行第一个字或图片都放不下才向下找下一条边。
      void below() {
        final next = band.nextBottom;
        if (parts.isEmpty) {
          start = next;
        } else {
          gap += next - y;
        }
        y = next;
        firstHeight = 0;
      }

      if (beside && available <= 0) {
        below();
        continue;
      }
      final measure = beside
          ? BlockMeasurer(
              options,
              styleTable: styleTable,
              displayTree: displayTree,
              normalFlow: false,
              floatLineEdges: (left: left, right: right),
            )
          : this;
      var part = offset == 0
          ? (beside ? measure.measure(block, withIndent: withIndent) : natural)
          : measure._measureText(
              _sliceDisplayBlock(block, offset, block.runLength),
              withIndent: false,
              sourceOffset: offset,
            );
      if (offset > 0 && part.bodyTop != 0) {
        part = part.withBoxEdges(
          first: false,
          last: part.boxLast,
          height: part.height - part.bodyTop,
          bodyTop: 0,
        );
      }
      final first = part.lines.firstOrNull;
      if (beside && first != null && first.width > available + .1) {
        below();
        continue;
      }
      var count = part.lines.length, lineTop = y + part.bodyTop;
      for (var i = 0; i < part.lines.length; i++) {
        final line = part.lines[i];
        final actual = floatLineInterval(
          floats,
          parentWidth,
          lineTop,
          height: line.height,
        );
        // 首行变窄后高度可能下降。保留已经避开的外框，可避免高、矮两种
        // 断法交替重试；下一行重新按自己的高度计算。
        final afterClear =
            i > 0 &&
            clearBottom(
                  offset + line.start - part.displayPrefixLength,
                  lineTop,
                ) >
                lineTop;
        final changed = i == 0
            ? actual.left > band.left || actual.right < band.right
            : actual.left != band.left || actual.right != band.right;
        // 例如段中一张 60% 宽的图片要等浮图结束，但它前面的字仍留在原行。
        if (afterClear || changed || (beside && line.width > available + .1)) {
          // 图片可以和下一行的文字共用一个原文偏移，不能将它复制到尾段。
          final split = i == 0 ? 0 : part.lines[i - 1].end;
          if (i == 0 ||
              (split > part.displayPrefixLength &&
                  split < part.text.length &&
                  !part.inlineImages.any(
                    (p) => p.line < i && p.offset == split,
                  ))) {
            count = i;
            firstHeight = math.max(i == 0 ? firstHeight : 0.0, line.height);
            break;
          }
        }
        lineTop += line.height;
      }
      if (count == 0 && first != null) continue;
      if (gap > 0) {
        part = part.withBoxEdges(
          first: part.boxFirst,
          last: part.boxLast,
          height: part.height + gap,
          bodyTop: part.bodyTop + gap,
        );
        gap = 0;
      }
      parts.add(part);
      // 全段都在同一栏宽时，分页直接用块边界，只有发生变化才记录分段。
      if (count < part.lines.length || intervals != null) {
        (intervals ??= []).add((left: left, right: right));
      }
      minLeft = math.min(minLeft, band.left);
      maxRight = math.max(maxRight, band.right);
      if (count == part.lines.length) break;
      limits[part] = count;
      offset += part.lines[count - 1].end - part.displayPrefixLength;
      y = lineTop;
    }
    final measured = parts.length == 1
        ? parts.single
        : _mergeDisplayText(
            block,
            parts,
            wholeParagraph: natural,
            lineLimits: limits,
            floatIntervals: intervals,
          );
    return (measured, start, minLeft, maxRight);
  }
}
