import 'package:taletin/ui/core/widgets/gt_button.dart';

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/theme/reading_theme.dart';
import '../../../core/theme/gt_tokens.dart';

/// 尖角指向实际标记；关闭和框内滚动均不提交阅读位置。
Future<void> showThoughtPopover(
  BuildContext context, {
  required Rect anchor,
  required String body,
  required ReadingTheme theme,
}) {
  final media = MediaQuery.of(context);
  final fontSize = media.textScaler.scale(16.0);
  final width = math.min(340.0, media.size.width - 32);
  final topSafe = media.padding.top + 12;
  final bottomSafe =
      media.size.height - media.padding.bottom - media.viewInsets.bottom - 12;
  final style = TextStyle(
    fontSize: 16,
    height: 1.5,
    color: theme.primary,
    fontFamily: Theme.of(context).textTheme.bodyMedium?.fontFamily,
  );
  final painter = TextPainter(
    text: TextSpan(text: body, style: style),
    textDirection: Directionality.of(context),
    textScaler: media.textScaler,
  )..layout(maxWidth: width - 32);
  final textHeight = math.min(painter.height, fontSize * 1.5 * 8);
  painter.dispose();
  final height = math.min(textHeight + 80, bottomSafe - topSafe);
  final below = anchor.bottom + 8 + height <= bottomSafe;
  final left = (anchor.center.dx - width / 2).clamp(
    16.0,
    media.size.width - width - 16,
  );
  final top = (below ? anchor.bottom + 8 : anchor.top - height - 8)
      .clamp(topSafe, math.max(topSafe, bottomSafe - height))
      .toDouble();
  final tip = (anchor.center.dx - left).clamp(14.0, width - 14);
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '关闭想法',
    barrierColor: Colors.transparent,
    transitionDuration: Duration.zero,
    pageBuilder: (context, _, _) => Stack(
      children: [
        Positioned(
          left: left,
          top: top,
          width: width,
          height: height,
          child: ThoughtPopover(
            body: body,
            style: style,
            theme: theme,
            tip: tip,
            below: below,
          ),
        ),
      ],
    ),
  );
}

class ThoughtPopover extends StatelessWidget {
  const ThoughtPopover({
    super.key,
    required this.body,
    required this.style,
    required this.theme,
    required this.tip,
    required this.below,
  });
  final String body;
  final TextStyle style;
  final ReadingTheme theme;
  final double tip;
  final bool below;
  @override
  Widget build(BuildContext context) => CustomPaint(
    painter: _BubblePainter(theme.background, theme.primary, tip, below),
    child: Material(
      color: Colors.transparent,
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, below ? 12 : 4, 16, below ? 4 : 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '想法',
                    style: style.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
                GtButton.icon(
                  tooltip: '关闭想法',
                  onPressed: () => Navigator.pop(context),
                  icon: Icon(Icons.close, color: theme.primary, size: 20),
                ),
              ],
            ),
            Flexible(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.textScalerOf(context).scale(16) * 12,
                ),
                child: SingleChildScrollView(
                  primary: false,
                  child: Text(body, style: style),
                ),
              ),
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    ),
  );
}

class _BubblePainter extends CustomPainter {
  const _BubblePainter(this.color, this.border, this.tip, this.below);
  final Color color, border;
  final double tip;
  final bool below;
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTRB(
      0,
      below ? 8 : 0,
      size.width,
      size.height - (below ? 0 : 8),
    );
    final edge = below ? rect.top : rect.bottom;
    final frame = Path()
      ..addRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(GtRadius.dialog)),
      );
    // 尖角底边稍进入框内，再合并外轮廓，连接处不再画横线或留下细缝。
    final base = edge + (below ? 1 : -1);
    final tail = Path()
      ..moveTo(tip - 7, base)
      ..lineTo(tip, below ? 0 : size.height)
      ..lineTo(tip + 7, base)
      ..close();
    final path = Path.combine(PathOperation.union, frame, tail);
    canvas.drawShadow(path, Colors.black38, 6, true);
    canvas.drawPath(path, Paint()..color = color);
    canvas.drawPath(
      path,
      Paint()
        ..color = border.withValues(alpha: 0.2)
        ..style = PaintingStyle.stroke,
    );
  }

  @override
  bool shouldRepaint(_BubblePainter old) =>
      old.color != color ||
      old.border != border ||
      old.tip != tip ||
      old.below != below;
}
