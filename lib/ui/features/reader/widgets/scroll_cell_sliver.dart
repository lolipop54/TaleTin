import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// 复用排版时算好的格子边界，滚到章尾时也不需要从第一个段落逐个累加高度。
class ScrollCellSliver extends SliverVariedExtentList {
  ScrollCellSliver({super.key, required super.delegate, required this.offsets})
    : super(itemExtentBuilder: (i, _) => offsets[i + 1] - offsets[i]);

  /// 包含第一个格子的起点和最后一个格子的终点。窗口替换时传入新的列表。
  final List<double> offsets;

  @override
  RenderSliverVariedExtentList createRenderObject(BuildContext context) =>
      _ScrollCellRenderSliver(
        childManager: context as SliverMultiBoxAdaptorElement,
        itemExtentBuilder: itemExtentBuilder,
        offsets: offsets,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    RenderSliverVariedExtentList renderObject,
  ) {
    super.updateRenderObject(context, renderObject);
    (renderObject as _ScrollCellRenderSliver).offsets = offsets;
  }
}

class _ScrollCellRenderSliver extends RenderSliverVariedExtentList {
  _ScrollCellRenderSliver({
    required super.childManager,
    required super.itemExtentBuilder,
    required this.offsets,
  });
  List<double> offsets;

  @override
  double indexToLayoutOffset(double itemExtent, int index) =>
      offsets[index.clamp(0, offsets.length - 1)];

  @override
  int getMinChildIndexForScrollOffset(double scrollOffset, double itemExtent) =>
      scrollCellIndexAt(offsets, scrollOffset);
  @override
  int getMaxChildIndexForScrollOffset(double scrollOffset, double itemExtent) =>
      scrollCellIndexAt(offsets, scrollOffset);
  @override
  double computeMaxScrollOffset(
    SliverConstraints constraints,
    double itemExtent,
  ) => offsets.last;
}

// Flutter 对恰好落在两格交界的坐标取前一格。保留这个约定，零高度格子也参与定位。
int scrollCellIndexAt(List<double> offsets, double offset) {
  if (offset <= 0 || offsets.length < 2) return 0;
  var lo = 1, hi = offsets.length - 1;
  while (lo < hi) {
    final mid = (lo + hi) ~/ 2;
    if (offsets[mid] < offset) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  return lo - 1;
}
