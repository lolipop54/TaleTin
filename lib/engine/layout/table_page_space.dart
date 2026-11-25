import 'dart:math' as math;

/// 连续坐标只累计表格正文可用的高度。已经绘过的表头从续页可用高度扣除，
/// 投影回实际纸面时再加回来。格框、跨行格边线和正文都使用相同的换算。
class TablePageSpace {
  TablePageSpace(this.height);

  final double height;
  int? repeatFrom, repeatThrough;
  double reserved = 0;

  int repeatedBefore(int page) {
    final from = repeatFrom;
    if (from == null || page <= from) return 0;
    return math.min(page, (repeatThrough ?? page) + 1) - from;
  }

  bool repeats(int page) =>
      repeatFrom != null &&
      page >= repeatFrom! &&
      (repeatThrough == null || page <= repeatThrough!);
  double top(int page) => page * height - repeatedBefore(page) * reserved;
  double end(int page) => top(page + 1);
  double local(double y, int page) =>
      y - top(page) + (repeats(page) ? reserved : 0);
  double capacity(int page) => repeats(page) ? height - reserved : height;

  int pageOf(double y) {
    const epsilon = .00001;
    final from = repeatFrom;
    if (from == null || y + epsilon < from * height) {
      return ((y + epsilon) / height).floor();
    }
    final after = repeatThrough == null ? null : repeatThrough! + 1;
    if (after != null && y + epsilon >= top(after)) {
      return after + ((y + epsilon - top(after)) / height).floor();
    }
    return from + ((y + epsilon - from * height) / (height - reserved)).floor();
  }
}
