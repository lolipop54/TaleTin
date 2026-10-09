import 'package:taletin/ui/core/widgets/gt_button.dart';
import 'package:flutter/material.dart';

/// 列表摘录和想法各自折叠；高亮按整行画矩形，避开字体回退的字形背景差异。
class AnnotationText extends StatefulWidget {
  const AnnotationText({
    super.key,
    required this.text,
    required this.label,
    required this.style,
    this.highlight,
    this.maxLines = 3,
    this.expandable = true,
  });
  final String text;
  final String label;
  final TextStyle style;
  final Color? highlight;
  final int maxLines;
  final bool expandable;
  @override
  State<AnnotationText> createState() => _AnnotationTextState();
}

class _AnnotationTextState extends State<AnnotationText> {
  bool _expanded = false;
  @override
  void didUpdateWidget(AnnotationText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) _expanded = false;
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final style = DefaultTextStyle.of(context).style
          .merge(widget.style)
          .copyWith(height: 1.5);
      final strut = StrutStyle.fromTextStyle(style, forceStrutHeight: true);
      final painter = TextPainter(
        text: TextSpan(text: widget.text, style: style),
        textDirection: Directionality.of(context),
        textAlign: TextAlign.justify,
        textScaler: MediaQuery.textScalerOf(context),
        locale: Localizations.maybeLocaleOf(context),
        strutStyle: strut,
        maxLines: _expanded ? null : widget.maxLines,
        ellipsis: _expanded ? null : '…',
      )..layout(maxWidth: constraints.maxWidth);
      final overflow = painter.didExceedMaxLines;
      final fontSize = MediaQuery.textScalerOf(context)
          .scale(style.fontSize ?? 16);
      final bands = [
        for (final line in painter.computeLineMetrics())
          // 每行只有一条底色，标点、中英文和 emoji 共用同一高度与基线。
          Rect.fromLTRB(
            line.left.clamp(0, constraints.maxWidth),
            line.baseline - fontSize,
            (line.left + line.width).clamp(0, constraints.maxWidth),
            line.baseline - fontSize + fontSize * 1.2,
          ),
      ];
      painter.dispose();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CustomPaint(
            painter: widget.highlight == null
                ? null
                : AnnotationHighlightPainter(bands, widget.highlight!),
            child: Text(
              widget.text,
              textAlign: TextAlign.justify,
              style: style,
              strutStyle: strut,
              maxLines: _expanded ? null : widget.maxLines,
              overflow: _expanded
                  ? TextOverflow.visible
                  : TextOverflow.ellipsis,
            ),
          ),
          if (widget.expandable && (overflow || _expanded))
            Align(
              alignment: Alignment.centerRight,
              child: GtButton(
                onPressed: () => setState(() => _expanded = !_expanded),
                style: GtButton.compactStyle,
                child: Text(
                  _expanded ? '收起' : '展开',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ),
        ],
      );
    },
  );
}

class AnnotationHighlightPainter extends CustomPainter {
  const AnnotationHighlightPainter(this.bands, this.color);
  final List<Rect> bands;
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    for (final band in bands) {
      canvas.drawRect(band, paint);
    }
  }

  @override
  bool shouldRepaint(AnnotationHighlightPainter oldDelegate) =>
      oldDelegate.bands != bands || oldDelegate.color != color;
}
