import 'package:flutter/material.dart';

import '../../../../core/theme/gt_tokens.dart';

/// 目录右侧的快速拖动条；和列表共用控制器，不额外保存滚动进度。
class TocScrollbar extends StatelessWidget {
  const TocScrollbar({
    super.key,
    required this.controller,
    required this.child,
  });

  final ScrollController controller;
  final Widget child;

  /// 始终留出触摸空间，滚动条淡入、淡出时不挤动章节文字。
  static const gutter = 48.0;
  static const _thickness = 6.0;
  static const _verticalInset = 8.0;
  static const _crossAxisMargin = (gutter - _thickness) / 2;

  @override
  Widget build(BuildContext context) {
    final colors = context.gtColors;
    // 从阅读底色向正文色稍微加深；夜间正文色更亮，仍能看清滑块。
    final thumbColor = Color.lerp(colors.surface, colors.textPrimary, .42)!;
    return _TocRawScrollbar(
      controller: controller,
      thumbColor: thumbColor,
      fadeDuration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : context.gtMotion.normal,
      child: ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
        child: child,
      ),
    );
  }
}

class _TocRawScrollbar extends RawScrollbar {
  _TocRawScrollbar({
    required super.controller,
    required super.thumbColor,
    required super.fadeDuration,
    required Widget child,
  }) : super(
         interactive: true,
         thickness: TocScrollbar._thickness,
         radius: const Radius.circular(TocScrollbar._thickness / 2),
         minThumbLength: TocScrollbar.gutter,
         mainAxisMargin: TocScrollbar._verticalInset,
         crossAxisMargin: TocScrollbar._crossAxisMargin,
         padding: EdgeInsets.zero,
         timeToFade: const Duration(milliseconds: 900),
         scrollbarOrientation: ScrollbarOrientation.right,
         child: _TocTrack(child: child),
       );

  @override
  RawScrollbarState<_TocRawScrollbar> createState() => _TocRawScrollbarState();
}

class _TocRawScrollbarState extends RawScrollbarState<_TocRawScrollbar> {
  Widget buildTrack(Widget child) => CustomPaint(
    // 轨道先画在列表上方，RawScrollbar 随后画滑块，两者共用淡出动画。
    foregroundPainter: _TocTrackPainter(
      scrollbar: scrollbarPainter,
      controller: widget.controller!,
      color: widget.thumbColor!.withValues(alpha: .32),
    ),
    child: child,
  );
}

/// 放在 RawScrollbar 内部，取得同一份绘制状态，避免另建显示计时器。
class _TocTrack extends StatelessWidget {
  const _TocTrack({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => context
      .findAncestorStateOfType<_TocRawScrollbarState>()!
      .buildTrack(child);
}

class _TocTrackPainter extends CustomPainter {
  _TocTrackPainter({
    required this.scrollbar,
    required this.controller,
    required this.color,
  }) : super(repaint: scrollbar);

  final ScrollbarPainter scrollbar;
  final ScrollController controller;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (!controller.hasClients || !controller.position.hasContentDimensions) {
      return;
    }
    final position = controller.position;
    final opacity = scrollbar.fadeoutOpacityAnimation.value;
    if (position.maxScrollExtent <= position.minScrollExtent || opacity == 0) {
      return;
    }
    const inset = TocScrollbar._verticalInset;
    if (size.height <= inset * 2) return;
    final x = size.width - TocScrollbar.gutter / 2;
    canvas.drawLine(
      Offset(x, inset),
      Offset(x, size.height - inset),
      Paint()
        ..color = color.withValues(alpha: color.a * opacity)
        ..strokeWidth = 1
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool? hitTest(Offset position) => false;

  @override
  bool shouldRepaint(_TocTrackPainter oldDelegate) =>
      oldDelegate.scrollbar != scrollbar ||
      oldDelegate.controller != controller ||
      oldDelegate.color != color;
}
