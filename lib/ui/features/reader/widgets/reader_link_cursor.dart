import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// 正文仍接收原有点击和拖动，只在可操作的文字或标记上提供手形指针。
class ReaderLinkCursor extends SingleChildRenderObjectWidget {
  const ReaderLinkCursor({
    super.key,
    required this.isLink,
    required super.child,
  });

  final bool Function(Offset point) isLink;

  @override
  RenderObject createRenderObject(BuildContext context) => _LinkRegion(isLink);

  @override
  void updateRenderObject(
    BuildContext context,
    RenderObject renderObject,
  ) {
    (renderObject as _LinkRegion).isLink = isLink;
  }
}

class _LinkRegion extends RenderMouseRegion {
  _LinkRegion(this.isLink) : super(cursor: SystemMouseCursors.click);

  bool Function(Offset) isLink;

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (!size.contains(position)) return false;
    final hit = hitTestChildren(result, position: position);
    if (isLink(position)) result.add(BoxHitTestEntry(this, position));
    return hit;
  }
}
