import 'package:flutter/material.dart';

/// 按图片实际占用区域识别空白，放大、平移后仍以变换后的边缘为准。
/// 用点击手势而非抬手事件关闭，避免双指缩放或拖动结束时误关。
class ReaderImageViewport extends StatelessWidget {
  const ReaderImageViewport({
    super.key,
    required this.imageSize,
    required this.transform,
    required this.onBlankTap,
    required this.child,
  });
  final Size imageSize;
  final TransformationController transform;
  final VoidCallback onBlankTap;
  final Widget child;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final fitted = applyBoxFit(
        BoxFit.contain,
        imageSize,
        constraints.biggest,
      );
      final imageRect = Alignment.center.inscribe(
        fitted.destination,
        Offset.zero & constraints.biggest,
      );
      return GestureDetector(
        excludeFromSemantics: true,
        behavior: HitTestBehavior.opaque,
        onTapUp: (details) {
          final point = transform.toScene(details.localPosition);
          if (!imageRect.contains(point)) onBlankTap();
        },
        child: InteractiveViewer(
          transformationController: transform,
          minScale: 1,
          maxScale: 8,
          child: SizedBox.expand(child: child),
        ),
      );
    },
  );
}
