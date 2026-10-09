import 'package:flutter/material.dart';

import '../../../../domain/models/reading_settings.dart';
import '../../../core/theme/gt_tokens.dart';
import '../../../core/widgets/gt_button.dart';
import '../../settings/widgets/font_choices.dart';
import 'reader_sheet.dart';

/// A− / 字号 / A+ / 当前字体横排；字号与字体名称互不挤压。
class ReaderFontControls extends StatelessWidget {
  const ReaderFontControls({
    super.key,
    required this.settings,
    required this.fontNames,
    required this.onSize,
    required this.onFont,
    this.supportsOriginalFont = true,
  });
  final ReadingSettings settings;
  final Map<String, String?> fontNames;
  final ValueChanged<int> onSize;
  final VoidCallback onFont;
  final bool supportsOriginalFont;

  @override
  Widget build(BuildContext context) {
    final colors = context.gtColors;
    final choices = readingFontChoices(
      settings,
      fontNames,
      supportsOriginalFont: supportsOriginalFont,
    );
    final selected = selectedFontChoice(
      settings,
      supportsOriginalFont: supportsOriginalFont,
    );
    final name = choices[selected] ?? selected;
    final fill = Color.lerp(ReaderSheet.backgroundOf(context), colors.textPrimary, .07)!;
    final scaler = MediaQuery.textScalerOf(context);
    // 大字号下保留完整A按钮和数值；只有字体名称允许省略。
    final stepWidth = (scaler.scale(12) * 2 + 12).clamp(52.0, 100.0);
    final numberWidth = (scaler.scale(14) * 2 + 4).clamp(32.0, 80.0);
    Widget button(String text, VoidCallback? action, {bool font = false}) =>
        GtButton.raw(
          tooltip: font
              ? name
              : text == 'A−'
              ? '减小字号'
              : '增大字号',
          borderRadius: BorderRadius.circular(24),
          onPressed: action,
          child: Container(
            alignment: Alignment.center,
            constraints: const BoxConstraints(minHeight: 48),
            padding: EdgeInsets.symmetric(horizontal: font ? 12 : 4),
            child: Container(
              width: double.infinity,
              alignment: Alignment.center,
              padding: EdgeInsets.symmetric(
                horizontal: font ? 8 : 2,
                vertical: 6,
              ),
              decoration: BoxDecoration(
                color: fill,
                borderRadius: BorderRadius.circular(24),
              ),
              child: Text(
                text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  color: action == null ? colors.textMuted : colors.textPrimary,
                ),
              ),
            ),
          ),
        );
    return Row(
      children: [
        Padding(padding: const EdgeInsets.only(right: 12),
          child: Text('字号', style: TextStyle(fontSize: 14, color: colors.textPrimary))),
        SizedBox(
          width: stepWidth,
          child: button(
            'A−',
            settings.fontSize > ReadingLimits.minFontSize
                ? () => onSize(settings.fontSize - 1)
                : null,
          ),
        ),
        SizedBox(
          width: numberWidth,
          child: Text(
            '${settings.fontSize}',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14, color: colors.textPrimary),
          ),
        ),
        SizedBox(
          width: stepWidth,
          child: button(
            'A+',
            settings.fontSize < ReadingLimits.maxFontSize
                ? () => onSize(settings.fontSize + 1)
                : null,
          ),
        ),
        Expanded(child: button(name, onFont, font: true)),
      ],
    );
  }
}
