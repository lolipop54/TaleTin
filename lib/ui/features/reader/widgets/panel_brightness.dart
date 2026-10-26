import 'package:taletin/ui/core/widgets/gt_switch.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/theme/gt_tokens.dart';
import '../../../../app/di/app_providers.dart';
import '../view_models/reader_settings_view_model.dart';
import '../view_models/reader_view_model.dart';
import 'reader_sheet.dart';
import 'reader_theme_choices.dart';
import '../../settings/widgets/reading_background_choices.dart';
import '../view_models/pdf_book_provider.dart';
import '../../settings/widgets/settings_slider.dart';

/// 亮度面板（参考图 03-2）。
/// 跟随系统开关与带百分比的应用窗口亮度滑块。
///
/// 亮度按单书保存；跟随系统时保留上一次自定义值，
/// 拖动滑块就写覆盖并立刻作用到窗口；离开阅读页窗口恢复原亮度（S14）。
class PanelBrightness extends ConsumerWidget {
  const PanelBrightness({super.key, required this.bookId});

  final String bookId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(readerSettingsProvider(bookId)).value;
    final colors = context.gtColors;
    final brightness = settings?.brightness;
    final followSystem = brightness == null;
    // 首次未自定义时才取系统值，切换跟随模式不改变滑块位置。
    final systemBrightness = ref.watch(systemBrightnessProvider).value;
    final shown =
        settings?.customBrightness ?? brightness ?? systemBrightness ?? 0.5;
    final vm = ref.read(readerSettingsProvider(bookId).notifier);

    return ReaderSheet(
      title: '亮度',
      onClose: () => ref.read(readerProvider.notifier).closePanel(),
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: GtSpacing.s5),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: GtSpacing.s2),
            // 跟随系统亮度
            Row(
              children: [
                Expanded(
                  child: Text('跟随系统亮度', style: GtText.body(colors.textPrimary)),
                ),
                GtSwitch(
                  value: followSystem,
                  onChanged: (follow) =>
                      vm.setBrightness(follow ? null : shown),
                ),
              ],
            ),
            const SizedBox(height: GtSpacing.s3),
            SettingsSlider(
              trackThickness: GtSliderSize.trackThicknessLarge,
              thumbRadius: GtSliderSize.thumbRadiusLarge,
              compact: true,
              backgroundColor: ReaderSheet.backgroundOf(context),
              label: '',
              value: shown,
              min: 0,
              max: 1,
              divisions: 100,
              format: (v) => '${(v * 100).round()}%',
              save: vm.setBrightness,
              onPreview: ref
                  .read(brightnessPreviewProvider(bookId).notifier)
                  .set,
              leading: Image.asset(
                'assets/icons_used/亮度-.webp',
                width: 24,
                height: 24,
                color: colors.textSecondary,
              ),
              trailing: Image.asset(
                'assets/icons_used/亮度+.webp',
                width: 24,
                height: 24,
                color: colors.textSecondary,
              ),
            ),
            if (!ref.watch(pdfModeProvider(bookId))) ...[
              const SizedBox(height: GtSpacing.s4),
              Container(height: 1, color: colors.borderSubtle),
              const SizedBox(height: GtSpacing.s3),
              Text(
                '阅读主题',
                style: GtText.body(colors.textSecondary).copyWith(fontSize: 14),
              ),
              const SizedBox(height: GtSpacing.s3),
              ReaderThemeChoices(bookId: bookId),
              const SizedBox(height: GtSpacing.s3),
              Text(
                '阅读背景',
                style: GtText.body(colors.textSecondary).copyWith(fontSize: 14),
              ),
              const SizedBox(height: GtSpacing.s3),
              ReadingBackgroundChoices(bookId: bookId),
            ],
            const SizedBox(height: GtSpacing.s4),
          ],
        ),
      ),
    );
  }
}
