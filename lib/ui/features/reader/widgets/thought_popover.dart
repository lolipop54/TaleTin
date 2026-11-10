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
  String title = '想法',
  String? actionLabel,
  VoidCallback? onAction,
}) {
  final media = MediaQuery.of(context);
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
  // 内容多时最多占安全高度的一大半，其余在框内滚动（脚注可能很长）
  final maxBodyHeight = (bottomSafe - topSafe) * 0.62;
  final textHeight = math.min(painter.height, maxBodyHeight);
  painter.dispose();
  final rowHeight = math.max(48.0, media.textScaler.scale(16) * 1.5);
  final height = math.min(
    textHeight + 16 + rowHeight + (actionLabel == null ? 12 : rowHeight),
    bottomSafe - topSafe,
  );
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
            title: title,
            actionLabel: actionLabel,
            onAction: onAction,
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
    this.title = '想法',
    this.actionLabel,
    this.onAction,
  });
  final String body;
  final TextStyle style;
  final ReadingTheme theme;
  final double tip;
  final bool below;
  final String title;
  final String? actionLabel;
  final VoidCallback? onAction;
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
            SizedBox(
              height: math.max(
                48.0,
                MediaQuery.textScalerOf(context).scale(16) * 1.5,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
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
            ),
            Flexible(
              fit: FlexFit.tight,
              // 弹窗外框已按文字和安全区算好高度，正文用完实际剩余空间。
              // 这里再设另一套上限，会在长注释的底部留下大块空白。
              child: SingleChildScrollView(
                primary: false,
                physics: const ClampingScrollPhysics(),
                child: Text(body, style: style),
              ),
            ),
            if (actionLabel != null && onAction != null)
              SizedBox(
                height: math.max(
                  48.0,
                  MediaQuery.textScalerOf(context).scale(16) * 1.5,
                ),
                child: Align(
                  alignment: Alignment.centerRight,
                  child: GtButton(
                    onPressed: onAction,
                    tooltip: actionLabel,
                    child: Text(
                      actionLabel!,
                      style: style.copyWith(
                        color: theme.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              )
            else
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
