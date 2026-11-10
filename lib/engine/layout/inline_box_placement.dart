import 'package:flutter/painting.dart';

import '../../domain/models/inline_box_span.dart';
import 'measured_block.dart';

/// 行内盒子跨行时各行上的实际矩形。坐标相对行首，分页只平移，不重新测量。
class InlineBoxPlacement {
  const InlineBoxPlacement({
    required this.span,
    required this.box,
    required this.line,
    required this.rect,
    required this.first,
    required this.last,
  });
  final InlineBoxSpan span;
  final BlockBox box;
  final int line;
  final Rect rect;
  final bool first, last;
}
