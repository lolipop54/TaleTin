import 'package:taletin/ui/core/widgets/gt_button.dart';
import 'package:flutter/material.dart';

import '../../../core/theme/gt_tokens.dart';
import '../../../core/theme/reading_theme.dart';
import '../../../core/widgets/gt_icon.dart';

/// 只显示主题底色；名称保留给读屏，选中卡片用边框和右下角圆圈勾提示。
class ReadingThemeCards extends StatelessWidget {
  const ReadingThemeCards({
    super.key,
    required this.selected,
    required this.onSelect,
  });
  final ReadingTheme selected;
  final ValueChanged<ReadingTheme> onSelect;
  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    child: Row(
      children: [
        for (final theme in ReadingTheme.displayOrder)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Semantics(
              label: theme.label,
              selected: theme == selected,
              child: Material(
                color: theme.background,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                  side: theme == selected
                      ? BorderSide(
                          color: context.gtColors.actionPrimary,
                          width: 2,
                        )
                      : BorderSide.none,
                ),
                clipBehavior: Clip.antiAlias,
                child: GtButton.raw(
                  onPressed: () => onSelect(theme),
                  child: SizedBox(
                    width: 80,
                    height: 48,
                    child: theme == selected
                        ? Align(
                            alignment: Alignment.bottomRight,
                            child: Padding(
                              padding: const EdgeInsets.all(5),
                              child: GtIcon(
                                GtIcons.checkCircle,
                                size: 20,
                                color: theme.primary,
                              ),
                            ),
                          )
                        : null,
                  ),
                ),
              ),
            ),
          ),
      ],
    ),
  );
}
