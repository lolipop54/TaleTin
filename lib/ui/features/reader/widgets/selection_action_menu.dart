import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../../data/services/offline_dictionary.dart';
import '../../../../domain/models/annotation.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/gt_tokens.dart';
import '../../../core/widgets/gt_button.dart';
import '../../../core/widgets/gt_icon.dart';

/// 把选文操作排成一行，按实际文字宽度为每个按钮分配空间。
class SelectionActionMenu extends StatelessWidget {
  const SelectionActionMenu({
    super.key,
    required this.existing,
    required this.onCopy,
    required this.onLookup,
    required this.onHighlight,
    required this.onColors,
    required this.onWriteNote,
    required this.onDelete,
  });

  final Annotation? existing;
  final VoidCallback onCopy;
  final VoidCallback? onLookup;
  final VoidCallback onHighlight;
  final VoidCallback onColors;
  final VoidCallback onWriteNote;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final colors = context.gtColors;
    final actions = [
      (icon: GtIcons.copy, label: '复制', onTap: onCopy),
      if (offlineDictionaryIncluded)
        if (onLookup case final lookup?)
          (icon: GtIcons.openBook, label: '查词', onTap: lookup),
      if (existing == null)
        (icon: GtIcons.highlight, label: '高亮', onTap: onHighlight)
      else
        (icon: GtIcons.palette, label: '颜色', onTap: onColors),
      (
        icon: existing == null ? GtIcons.notePlus : GtIcons.note,
        label: existing?.isNote == true ? '编辑想法' : '写想法',
        onTap: onWriteNote,
      ),
      if (onDelete case final delete?)
        (icon: GtIcons.trash, label: '删除', onTap: delete),
    ];
    return Material(
      color: colors.surface,
      elevation: 4,
      borderRadius: BorderRadius.circular(GtRadius.control),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final style = DefaultTextStyle.of(context).style
              .merge(GtText.body(colors.textPrimary).copyWith(fontSize: 14));
          final painter = TextPainter(
            textDirection: Directionality.of(context),
            textScaler: MediaQuery.textScalerOf(context),
            locale: Localizations.maybeLocaleOf(context),
            maxLines: 1,
          );
          final measuredStyle = MediaQuery.boldTextOf(context)
              ? style.copyWith(fontWeight: FontWeight.bold)
              : style;
          final widths = [
            for (final action in actions)
              (painter
                    ..text = TextSpan(text: action.label, style: measuredStyle)
                    ..layout())
                  .width,
          ];
          painter.dispose();

          final available = constraints.maxWidth;
          final widthPerButton = available / actions.length;
          final tapWidth = math.min(48.0, widthPerButton);
          final minPadding = math.min(GtSpacing.s1 / 2, widthPerButton / 8);
          final minGap = 2 * minPadding;
          final minSpacing = 2 * minPadding + minGap;
          const normalSpacing = 2 * GtSpacing.s4 + GtSpacing.s2;
          var iconSize = math.min(20.0, widthPerButton / 2);
          double buttonWidth(double labelWidth, double spacing) =>
              math.max(tapWidth, iconSize + spacing + labelWidth);
          double rowWidth(double spacing, double scale) => widths.fold(
            0.0,
            (sum, width) => sum + buttonWidth(width * scale, spacing),
          );

          // 先收紧留白。最紧的间距仍放不下时，先缩小图标，再等比缩小文字。
          if (rowWidth(minSpacing, 1) > available) {
            iconSize = math.min(16.0, iconSize);
          }
          final compactWidth = rowWidth(minSpacing, 1);
          final extraPerButton =
              math.max(0.0, available - compactWidth) / actions.length;
          final room = (extraPerButton / (normalSpacing - minSpacing)).clamp(
            0.0,
            1.0,
          );
          final padding = minPadding + (GtSpacing.s4 - minPadding) * room;
          final gap = minGap + (GtSpacing.s2 - minGap) * room;
          final spacing = 2 * padding + gap;
          var labelScale = 1.0;
          if (compactWidth > available) {
            // 按钮有最小触摸宽度，用同一比例试算所有标签，保持字号一致。
            var low = 0.0;
            var high = 1.0;
            for (var step = 0; step < 12; step++) {
              final middle = (low + high) / 2;
              if (rowWidth(spacing, middle) <= available) {
                low = middle;
              } else {
                high = middle;
              }
            }
            labelScale = low;
          }

          return Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final (index, action) in actions.indexed)
                GtButton.raw(
                  onPressed: action.onTap,
                  borderRadius: BorderRadius.circular(GtRadius.control),
                  child: ConstrainedBox(
                    constraints: BoxConstraints.tightFor(
                      width: buttonWidth(widths[index] * labelScale, spacing),
                    ).copyWith(minHeight: 48),
                    child: Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: padding,
                        vertical: GtSpacing.s2,
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          GtIcon(
                            action.icon,
                            size: iconSize,
                            color: action.icon == GtIcons.trash
                                ? colors.danger
                                : colors.actionPrimary,
                          ),
                          SizedBox(width: gap),
                          SizedBox(
                            width: widths[index] * labelScale,
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text(
                                action.label,
                                maxLines: 1,
                                softWrap: false,
                                style: action.icon == GtIcons.trash
                                    ? style.copyWith(color: colors.danger)
                                    : style,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
