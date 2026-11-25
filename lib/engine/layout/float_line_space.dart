import 'dart:math' as math;
import 'dart:ui';

typedef FloatFootprint = ({Rect bounds, bool right});
typedef LineInterval = ({double left, double right, double nextBottom});

/// 一行与哪些浮动外框相交，就避开哪些外框。坐标属于同一个包含块。
LineInterval floatLineInterval(
  Iterable<FloatFootprint> floats,
  double width,
  double top, {
  double height = 0,
}) {
  var left = 0.0, right = width, nextBottom = double.infinity;
  for (final item in floats) {
    final rect = item.bounds;
    if (rect.bottom <= top + .001 || rect.top >= top + math.max(.001, height)) {
      continue;
    }
    if (item.right) {
      right = math.min(right, rect.left);
    } else {
      left = math.max(left, rect.right);
    }
    nextBottom = math.min(nextBottom, rect.bottom);
  }
  return (left: left, right: right, nextBottom: nextBottom);
}
