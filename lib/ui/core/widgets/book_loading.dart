import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/gt_tokens.dart';

/// 五个方块依次跳起、轻转后落回；起跳后原位置留空，不画副本。
class BookLoading extends StatefulWidget {
  const BookLoading({super.key, this.color, this.label});
  final Color? color;

  /// 显示在方块正下方的说明；不传时保持只显示动画。
  final String? label;

  @override
  State<BookLoading> createState() => _BookLoadingState();
}

class _BookLoadingState extends State<BookLoading>
    with SingleTickerProviderStateMixin {
  late final _turn = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2000),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _turn.stop();
      _turn.value = 0;
    } else {
      _turn.repeat();
    }
  }

  @override
  void dispose() {
    _turn.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 逐帧只重绘方块，下面的说明文字不参与动画重绘。
    final blocks = RepaintBoundary(
      child: SizedBox(
        width: 104,
        height: 40,
        child: CustomPaint(
          painter: _BlocksPainter(
            _turn,
            widget.color ??
                (Theme.of(context).brightness == Brightness.dark
                    ? GtColors.dark.actionPrimary
                    : GtColors.light.actionPrimary),
          ),
        ),
      ),
    );
    if (widget.label == null) return blocks;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        blocks,
        const SizedBox(height: GtSpacing.s3),
        Text(
          widget.label!,
          textAlign: TextAlign.center,
          style: GtText.body(context.gtColors.textSecondary)
              .copyWith(fontSize: 14),
        ),
      ],
    );
  }
}

class _BlocksPainter extends CustomPainter {
  _BlocksPainter(this.turn, this.color) : super(repaint: turn);
  final Animation<double> turn;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    // 画布只重绘104×40dp，颜色保持主色色相，逐块改变亮度和饱和度。
    canvas.scale(size.width / 104, size.height / 40);
    final base = HSLColor.fromColor(color);
    for (var i = 0; i < 5; i++) {
      final phase = ((turn.value - i * .095) / .27).clamp(0.0, 1.0);
      final jump = math.sin(math.pi * phase);
      final lift = 18 * jump;
      final lightness = (base.lightness + (i - 2) * .105).clamp(.14, .88);
      final ink = Paint()
        ..color = base
            .withLightness(lightness)
            .withSaturation((base.saturation - i * .045).clamp(0, 1))
            .toColor();
      canvas.save();
      canvas.translate(12 + i * 20 - 4 * jump, 29 - lift);
      canvas.rotate(.15 * math.sin(phase * math.pi * 2));
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: Offset.zero,
            width: 15,
            height: 15 - 2 * math.sin(phase * math.pi * 2),
          ),
          const Radius.circular(1.7),
        ),
        ink,
      );
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_BlocksPainter old) =>
      old.color != color || old.turn != turn;
}
