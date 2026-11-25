import 'dart:math' as math;

import 'measured_block.dart';
import 'vertical_margins.dart';

/// The ordinary-flow gap also includes every empty box passed along the way.
/// Reader spacing is a floor for positive margins only.
double resolveBlockGap(
  MeasuredBlock? previous,
  MeasuredBlock current, {
  required double baseline,
  VerticalMargin? intervening,
}) {
  var margin = current.leadingMargin;
  if (previous != null) margin = margin.join(previous.trailingMargin);
  if (intervening != null) margin = margin.join(intervening);
  return margin.negative < 0
      ? margin.extent
      : math.max(baseline, margin.extent);
}
