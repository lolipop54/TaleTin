part of 'block_measure.dart';

extension BlockFlowSpacing on BlockMeasurer {
  /// 块之间是否需要段距：表格外的所有文本块之间都补，图片与分隔线自带留白。
  ///
  /// 同一个盒子容器里的连续块不补段距：背景与左右边框要连成一整块。
  double gapBefore(
    MeasuredBlock previous,
    MeasuredBlock current, {
    VerticalMargin? intervening,
  }) {
    var margin = previous.trailingMargin.join(current.leadingMargin);
    if (intervening != null) margin = margin.join(intervening);
    if (margin.negative < 0) {
      final gap = margin.extent;
      return gap < 0 ? _readableTextGap.resolve(previous, current, gap) : gap;
    }
    // 新显示框的身份来自真实来源元素，直接文字、表格和空元素也能共用。
    // 旧 boxId 只在没有显示树资料时负责兼容，不能把同一容器切出额外段距。
    final shared = previous.containerBoxes.map((f) => f.elementId).toSet();
    if (current.containerBoxes.any((f) => shared.contains(f.elementId))) {
      return margin.extent;
    }
    if (current.isDecoration && !current.isTitleDecoration) {
      return margin.extent;
    }
    if (previous.isDecoration && previous.kind == BlockKind.divider) {
      // hr 的高度和 CSS 外边距已进入测量，不再在线后叠一份阅读器段距。
      return margin.extent;
    }
    if (previous.isDecoration && !previous.isTitleDecoration) {
      final first = previous.decorationAtStart;
      final base = first
          ? 0.0
          : (options.gapBefore(previous.kind, current.kind) ??
                options.paragraphGap);
      return math.max(base, margin.extent);
    }
    if (previous.boxId != null && previous.boxId == current.boxId) {
      return intervening == null ? 0 : margin.extent;
    }
    if (current.kind == BlockKind.divider) {
      return intervening == null
          ? options.paragraphGap
          : math.max(options.paragraphGap, margin.extent);
    }
    final tree = displayTree;
    if (tree != null && tree.compactLists.isNotEmpty) {
      int? compact(String blockId) {
        final index = tree.blockIndexById[blockId];
        return index == null
            ? null
            : tree.chains[index]
                  .where((c) => tree.compactLists.contains(c.elementId))
                  .lastOrNull
                  ?.elementId;
      }

      final list = compact(previous.blockId);
      if (list != null && list == compact(current.blockId)) {
        return margin.extent;
      }
    }
    final base =
        options.gapBefore(previous.kind, current.kind) ?? options.paragraphGap;
    return math.max(base, margin.extent);
  }
}

/// 只在负段距把相邻文字行拉进同一区域时，查询文字的实际位置。
/// 坐标以两块原本相接的边缘为零点，行首空白、图片和边框不算作文字。
class _ReadableTextGap {
  _ReadableTextGap(this.options);
  final LayoutOptions options;
  final _boxes = Expando<Map<int, List<Rect>>>();

  List<Rect> _ink(MeasuredBlock block, int index) {
    final lines = _boxes[block] ??= {};
    return lines.putIfAbsent(index, () {
      final width = block.layoutWidth ?? options.contentWidthFor(block.kind);
      return block.readableRectsInLine(index, options.textScaler, width);
    });
  }

  double resolve(MeasuredBlock before, MeasuredBlock after, double gap) {
    if (!before.isText ||
        !after.isText ||
        before.pageTop != null ||
        after.pageTop != null ||
        before.tableId != null ||
        after.tableId != null ||
        before.isDecoration ||
        after.isDecoration) {
      return gap;
    }
    final bottom = -before.bodyBottom;
    final start = gap + after.bodyTop;
    if (start >= bottom) return gap;

    // 只访问负边距所跨过的行。标题防孤悬、分页与分段重放再次查询时可复用字框。
    var first = before.lines.length - 1;
    var top = bottom - before.lines[first].height;
    while (first > 0 && top > start) {
      top -= before.lines[--first].height;
    }
    var shift = 0.0;
    while (start + shift < bottom) {
      var nextShift = shift, i = first, j = 0;
      var y = top, z = start + shift;
      while (i < before.lines.length && j < after.lines.length) {
        final endY = y + before.lines[i].height,
            endZ = z + after.lines[j].height;
        if (y < endZ && z < endY) {
          final a = _ink(before, i), b = _ink(after, j);
          for (final r in a) {
            for (final s in b) {
              if (r.left < s.right &&
                  s.left < r.right &&
                  y + r.top < z + s.bottom &&
                  z + s.top < y + r.bottom) {
                nextShift = math.max(
                  nextShift,
                  shift + y + r.bottom - z - s.top + 1,
                );
              }
            }
          }
        }
        if (endY <= endZ) {
          i++;
          y = endY;
        }
        if (endZ <= endY) {
          j++;
          z = endZ;
        }
      }
      if (shift == nextShift) break;
      shift = nextShift;
    }
    // 标题有下划线式的底边时，文字避开标题后也不能正好落在线上。
    // 仅当刚才确有文字相压才检查边线，普通装饰叠放仍按原书位置。
    if (shift > 0) {
      void clearBorder(BlockBox box, double left, double right, double edge) {
        if (box.borderBottom <= 0 || box.borderColors[2].a == 0) return;
        for (final r in _ink(after, 0)) {
          final y = start + shift;
          if (r.left < right &&
              left < r.right &&
              y + r.top < edge &&
              y + r.bottom > edge - box.borderBottom) {
            shift = math.max(shift, edge - start - r.top + 1);
          }
        }
      }

      final box = before.box;
      if (box != null && before.boxLast) {
        clearBorder(
          box,
          before.inset - box.insetLeft - before.boxIndent,
          before.inset +
              (before.layoutWidth ?? options.contentWidth) +
              box.insetRight,
          box.insetBottom - before.bodyBottom,
        );
      }
      for (final f in before.containerBoxes) {
        if (f.last &&
            f.height == null &&
            (f.lineTo ?? before.lines.length) == before.lines.length) {
          clearBorder(f.box, f.left, f.left + f.width, -f.bottom);
        }
      }
    }
    return gap + shift;
  }
}
