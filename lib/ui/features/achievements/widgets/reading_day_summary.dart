import 'package:flutter/material.dart';

import '../../../core/theme/gt_tokens.dart';
import '../../../core/widgets/gt_icon.dart';

/// 更改寄语后运行 tools/fonts/generate_quote.py，字库只保留这些字形。
const readingDayQuote = '每一段专注的时光，\n都是在靠近更好的自己。';

/// 附件中的淡绿时长卡片：大数字、手写寄语和轻微倾斜的下划线。
class ReadingDaySummary extends StatelessWidget {
  const ReadingDaySummary({super.key, required this.totalMs});
  final int totalMs;
  @override
  Widget build(BuildContext context) {
    final colors = context.gtColors;
    final minutes = totalMs ~/ 60000;
    const green = Color(0xFF739F82);
    final number = TextStyle(
      fontSize: 28,
      fontWeight: FontWeight.w700,
      height: 1.25,
      color: colors.textPrimary,
    );
    final unit = number.copyWith(fontSize: 12, fontWeight: FontWeight.w500);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
      decoration: BoxDecoration(
        color: Color.alphaBlend(green.withValues(alpha: .055), colors.surface),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Expanded(
            flex: 6,
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: green.withValues(alpha: .13),
                  ),
                  child: Center(
                    child: GtIcon(GtIcons.openBook, size: 23, color: green),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '总时长',
                        style: TextStyle(
                          fontSize: 12,
                          color: colors.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 3),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text.rich(
                          TextSpan(
                            children: [
                              if (minutes >= 60) ...[
                                TextSpan(
                                  text: '${minutes ~/ 60}',
                                  style: number,
                                ),
                                TextSpan(text: ' 小时 ', style: unit),
                              ],
                              if (totalMs > 0 && minutes == 0) ...[
                                TextSpan(
                                  text: totalMs < 1000
                                      ? '不足1'
                                      : '${totalMs ~/ 1000}',
                                  style: number,
                                ),
                                TextSpan(text: ' 秒', style: unit),
                              ] else ...[
                                TextSpan(
                                  text: '${minutes % 60}',
                                  style: number,
                                ),
                                TextSpan(text: ' 分钟', style: unit),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 5,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Transform.rotate(
                angle: -.08,
                child: Column(
                  children: [
                    Text(
                      readingDayQuote,
                      style: TextStyle(
                        fontFamily: 'ReadingQuote',
                        fontSize: 14,
                        height: 1.75,
                        letterSpacing: 1.2,
                        color: colors.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    SizedBox(
                      width: 92,
                      height: 5,
                      child: CustomPaint(painter: _QuoteLine(green)),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _QuoteLine extends CustomPainter {
  const _QuoteLine(this.color);
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final line = Path()
      ..moveTo(0, 4)
      ..quadraticBezierTo(size.width * .45, 0, size.width, 1);
    canvas.drawPath(
      line,
      Paint()
        ..color = color.withValues(alpha: .4)
        ..style = PaintingStyle.stroke
        ..strokeWidth = .8,
    );
  }

  @override
  bool shouldRepaint(_QuoteLine oldDelegate) => oldDelegate.color != color;
}
