import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';

import '../../../../app/router/main_pages_ready.dart';
import '../../../core/theme/gt_tokens.dart';
import '../../../core/widgets/gt_button.dart';
import '../../../core/widgets/gt_scroll_input_scope.dart';
import '../../../core/widgets/touch_frame_sampling.dart';

/// 书架滚动区：保留系统拉伸，顶部固定渐隐，并统一裁掉绘制越界。
class ShelfScrollArea extends StatelessWidget {
  const ShelfScrollArea({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => ClipRect(
    child: CustomPaint(
      foregroundPainter: _TopFadePainter(
        background: context.gtColors.canvas,
        pixel: 1 / MediaQuery.devicePixelRatioOf(context),
      ),
      child: GtScrollInputScope(
        behavior: const _ShelfScrollBehavior(),
        child: child,
      ),
    ),
  );
}

/// 仅浮钮监听滚动边界，滑动期间不重建书架条目。
class ShelfScrollToTop extends StatefulWidget {
  const ShelfScrollToTop({super.key, required this.builder});
  final Widget Function(ScrollController controller) builder;
  @override
  State<ShelfScrollToTop> createState() => _ShelfScrollToTopState();
}

class _ShelfScrollToTopState extends State<ShelfScrollToTop> {
  final _scroll = ScrollController();
  final _visible = ValueNotifier(false);
  final _sampling = TouchFrameSampling();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 隐藏的书架分支仍会保留列表。只有实际可操作的 Android 书架请求触点对齐。
    if (defaultTargetPlatform == TargetPlatform.android &&
        MainPagesReady.shelfIsInteractive(context) &&
        (ModalRoute.isCurrentOf(context) ?? true)) {
      _sampling.acquire();
    } else {
      _sampling.release();
    }
  }

  void _syncVisibility() {
    if (!_scroll.hasClients || _scroll.positions.length != 1) return;
    final pos = _scroll.position;
    if (pos.hasContentDimensions) {
      _visible.value =
          pos.maxScrollExtent > pos.minScrollExtent &&
          pos.pixels > pos.minScrollExtent;
    }
  }

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_syncVisibility);
  }

  @override
  void dispose() {
    _sampling.release();
    _scroll.dispose();
    _visible.dispose();
    super.dispose();
  }

  void _returnToTop() {
    if (!_scroll.hasClients) return;
    final top = _scroll.position.minScrollExtent;
    if (MediaQuery.disableAnimationsOf(context)) {
      _scroll.jumpTo(top);
    } else {
      _scroll.animateTo(
        top,
        duration: context.gtMotion.normal,
        curve: Curves.easeOut,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.gtColors;
    return Stack(
      fit: StackFit.expand,
      children: [
        NotificationListener<ScrollMetricsNotification>(
          onNotification: (event) {
            // 筛选结果变短和窗口变高都可能直接回到顶部，并不产生拖动事件。
            if (event.depth == 0) _syncVisibility();
            return false;
          },
          child: ShelfScrollArea(child: widget.builder(_scroll)),
        ),
        Positioned(
          right: GtSpacing.s4,
          bottom: MediaQuery.paddingOf(context).bottom + GtSpacing.s4,
          child: ValueListenableBuilder<bool>(
            valueListenable: _visible,
            builder: (_, visible, child) =>
                visible ? child! : const SizedBox.shrink(),
            child: GtButton.icon(
              key: const ValueKey('shelf-back-to-top'),
              onPressed: _returnToTop,
              style: ButtonStyle(
                minimumSize: const WidgetStatePropertyAll(Size.square(48)),
                shape: const WidgetStatePropertyAll(CircleBorder()),
                backgroundColor: WidgetStatePropertyAll(colors.actionPrimary),
              ),
              icon: Icon(
                Icons.arrow_upward_rounded,
                semanticLabel: '回到顶部',
                size: 23,
                color: colors.onPrimary,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 拉伸单独采样内容，顶部和两侧的留白也需要不透明底色。
class _ShelfScrollBehavior extends GtScrollBehavior {
  const _ShelfScrollBehavior();

  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) => super.buildOverscrollIndicator(
    context,
    ColoredBox(color: context.gtColors.canvas, child: child),
    details,
  );
}

class _TopFadePainter extends CustomPainter {
  const _TopFadePainter({required this.background, required this.pixel});

  final Color background;
  final double pixel;

  @override
  void paint(Canvas canvas, Size size) {
    // 分类栏高度可能落在半个屏幕像素上。矩形向上多画一像素，
    // 首像素保持实色，避免矩形抗锯齿边缘漏出下面的深色封面。
    // 最外层 ClipRect 同时裁掉拉伸滤镜和渐变的越界绘制；
    // Stack 默认只按布局溢出裁剪，不能保证滤镜绘制仍在边界内。
    final bounds = Rect.fromLTWH(0, 0, size.width, GtSpacing.s4);
    canvas.drawRect(
      Rect.fromLTRB(0, -pixel, size.width, GtSpacing.s4),
      Paint()
        ..isAntiAlias = false
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [background, background, background.withValues(alpha: 0)],
          stops: [0, pixel / GtSpacing.s4, 1],
        ).createShader(bounds),
    );
  }

  @override
  bool shouldRepaint(_TopFadePainter oldDelegate) =>
      background != oldDelegate.background || pixel != oldDelegate.pixel;
}
