import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/theme/gt_tokens.dart';
import '../../../core/theme/reading_theme.dart';
import '../../../core/widgets/gt_button.dart';
import '../../../core/widgets/gt_icon.dart';
import '../view_models/reader_settings_view_model.dart';

/// 亮度下方的单书阅读主题；沿用四色块、选中勾号和原来的保存方法。
class ReaderThemeChoices extends ConsumerWidget {
  const ReaderThemeChoices({super.key, required this.bookId});
  final String bookId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(readerSettingsProvider(bookId)).value!;
    final vm = ref.read(readerSettingsProvider(bookId).notifier);
    final colors = context.gtColors;
    return Row(
      children: [
        for (final (theme, label) in [
          (ReadingTheme.white, '明亮'),
          (ReadingTheme.paper, '柔和'),
          (ReadingTheme.green, '护眼'),
          (ReadingTheme.night, '夜间'),
        ]) ...[
          Expanded(
            child: GtButton.raw(
              borderRadius: BorderRadius.circular(GtRadius.control),
              onPressed: () => vm.setTheme(theme),
              child: Column(
                children: [
                  Stack(
                    children: [
                      Container(
                        height: 44,
                        decoration: BoxDecoration(
                          color: theme.background,
                          borderRadius: BorderRadius.circular(GtRadius.control),
                          border: Border.all(
                            width: settings.theme == theme ? 2 : 1,
                            color: settings.theme == theme
                                ? colors.actionPrimary
                                : colors.borderSubtle,
                          ),
                        ),
                      ),
                      if (settings.theme == theme)
                        Positioned(
                          bottom: 3,
                          right: 3,
                          child: GtIcon(
                            GtIcons.checkCircle,
                            size: 16,
                            color: colors.actionPrimary,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: GtSpacing.s1),
                  Text(
                    label,
                    style: GtText.caption(colors.textSecondary)
                        .copyWith(fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
          if (theme != ReadingTheme.night) const SizedBox(width: GtSpacing.s3),
        ],
      ],
    );
  }
}
