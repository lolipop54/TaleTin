import 'dart:math' as math;

import 'package:taletin/ui/core/widgets/gt_switch.dart';
import 'package:taletin/ui/core/widgets/gt_app_bar.dart';
import 'package:taletin/ui/core/widgets/gt_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/di/app_providers.dart';
import '../../../../app/di/app_font_providers.dart';
import '../../../../domain/models/reading_settings.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/gt_tokens.dart';
import '../../../core/theme/reading_theme.dart';
import '../view_models/global_reading_settings.dart';
import '../widgets/settings_action.dart';
import '../widgets/typography_cards.dart';
import '../widgets/settings_slider.dart';
import '../widgets/settings_row.dart';
import '../widgets/settings_page.dart';
import '../widgets/font_weight_tabs.dart';
import 'global_font_view.dart';

/// 全局默认值与单书面板共用模型、真实字体和仓库；此页面不写任何单书值。
class GlobalTypographyView extends ConsumerWidget {
  const GlobalTypographyView({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(globalSettingsProvider);
    final fonts = ref.watch(currentTypographyFontsProvider).value;
    final current = data.value;
    final vm = ref.read(globalSettingsProvider.notifier);
    ReadingTheme themeOf(String? id) =>
        ReadingTheme.values.where((theme) => theme.name == id).firstOrNull ??
        kDefaultReadingTheme;
    final s = current?.typography;
    // 缩进、显示开关、加粗与字号使用一致的行高；按真实数字尺寸容纳大字号。
    var typographyRowHeight = 48.0;
    for (final value in [
      ReadingLimits.minFontSize,
      ReadingLimits.maxFontSize,
    ]) {
      final number = TextPainter(
        text: TextSpan(
          text: '$value',
          style: TextStyle(
            fontFamily: Theme.of(context).textTheme.bodyMedium?.fontFamily,
            fontSize: 13,
            fontWeight: FontWeight.bold,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
      )..layout();
      typographyRowHeight = math.max(
        typographyRowHeight,
        math.max(number.width, number.height) + 10,
      );
      number.dispose();
    }
    void change(ReadingSettings Function(ReadingSettings) update) =>
        saveSetting(context, () => vm.change(update));
    return Scaffold(
      appBar: GtAppBar(title: const Text('全局字体与排版')),
      body: SafeArea(
        child: current == null || fonts == null
            ? Center(
                child: data.hasError
                    ? GtButton(
                        onPressed: () => ref.invalidate(globalSettingsProvider),
                        child: const Text('读取失败，点击重试'),
                      )
                    : const SizedBox.shrink(),
              )
            : ListView.separated(
                padding: const EdgeInsets.all(20),
                separatorBuilder: (context, index) => SizedBox(height: 8),
                itemCount: 12,
                itemBuilder: (context, index) => SizedBox(
                  height: index >= 2 && index <= 6 ? typographyRowHeight : null,
                  child: [
                    SettingsRow(
                      divider: false,
                      label: '排版模式',
                      value: s!.layoutMode.isOriginal ? '原书排版' : '简化排版',
                      onTap: () => openSettingsPage(
                        context,
                        SettingsChoices<ReadingLayoutMode>(
                          title: '排版模式',
                          options: ReadingLayoutMode.values,
                          label: (v) => v.isOriginal ? '原书排版' : '简化排版',
                          selected: (ref) => ref
                              .watch(globalSettingsProvider)
                              .requireValue
                              .typography
                              .layoutMode,
                          save: (ref, v) => ref
                              .read(globalSettingsProvider.notifier)
                              .change((s) => s.copyWith(layoutMode: v)),
                        ),
                      ),
                    ),
                    SettingsRow(
                      divider: false,
                      label: '字体',
                      value: globalFontChoice(s) == '__original'
                          ? '原书字体'
                          : globalFontChoice(s) == 'sans-serif'
                          ? '系统字体'
                          : fonts[globalFontChoice(s)] ?? globalFontChoice(s),
                      onTap: () => openSettingsPage(
                        context,
                        const GlobalFontView(),
                        ready: fontFamilyNamesProvider.future,
                      ),
                    ),
                    SettingsRow(
                      divider: false,
                      label: '首行缩进',
                      trailing: GtSwitch(
                        value: s.indent,
                        onChanged: (v) => change((s) => s.copyWith(indent: v)),
                      ),
                    ),
                    SettingsRow(
                      divider: false,
                      label: '书边效果',
                      trailing: GtSwitch(
                        key: const Key('global-book-edges-switch'),
                        value: s.bookEdges,
                        onChanged: (v) =>
                            change((s) => s.copyWith(bookEdges: v)),
                      ),
                    ),
                    SettingsRow(
                      divider: false,
                      label: '横屏',
                      trailing: GtSwitch(
                        key: const Key('global-landscape-switch'),
                        value: s.landscape,
                        onChanged: (v) =>
                            change((s) => s.copyWith(landscape: v)),
                      ),
                    ),
                    SettingsRow(
                      divider: false,
                      label: '横屏双翻页',
                      trailing: GtSwitch(
                        key: const Key('global-landscape-spread-switch'),
                        value: s.landscapeSpread,
                        onChanged: (v) =>
                            change((s) => s.copyWith(landscapeSpread: v)),
                      ),
                    ),
                    SettingsRow(
                      divider: false,
                      label: '字体加粗',
                      trailing: SizedBox(
                        // 给四字标签保留完整宽度；窄屏大字号下仅收紧右侧选项。
                        width: math.min(
                          204,
                          math.max(
                            132,
                            MediaQuery.sizeOf(context).width -
                                52 -
                                MediaQuery.textScalerOf(context).scale(14) * 4,
                          ),
                        ),
                        child: FontWeightTabs(
                          value: s.fontWeight,
                          onChanged: (v) =>
                              change((s) => s.copyWith(fontWeight: v)),
                        ),
                      ),
                    ),
                    SettingsSlider(
                      labelStyle: GtText.body(context.gtColors.textPrimary)
                          .copyWith(fontSize: 14),
                      thumbRadius: GtSliderSize.thumbRadiusSmall,
                      trackThickness: GtSliderSize.trackThicknessSmall,
                      label: '字号',
                      value: s.fontSize.toDouble(),
                      min: ReadingLimits.minFontSize.toDouble(),
                      max: ReadingLimits.maxFontSize.toDouble(),
                      divisions:
                          ReadingLimits.maxFontSize - ReadingLimits.minFontSize,
                      format: (v) => v.round().toString(),
                      save: (v) => vm.change((s) => s.withFontSize(v.round())),
                    ),
                    SettingsSlider(
                      labelStyle: GtText.body(context.gtColors.textPrimary)
                          .copyWith(fontSize: 14),
                      thumbRadius: GtSliderSize.thumbRadiusSmall,
                      trackThickness: GtSliderSize.trackThicknessSmall,
                      label: '行高',
                      value: s.lineHeight,
                      min: 1.2,
                      max: 2.2,
                      divisions: 10,
                      format: (v) => v.toStringAsFixed(1),
                      save: (v) => vm.change((s) => s.copyWith(lineHeight: v)),
                    ),
                    SettingsSlider(
                      labelStyle: GtText.body(context.gtColors.textPrimary)
                          .copyWith(fontSize: 14),
                      thumbRadius: GtSliderSize.thumbRadiusSmall,
                      trackThickness: GtSliderSize.trackThicknessSmall,
                      label: '段落间距',
                      // 与阅读面板一致：显示整数像素，保存时按当前字号换回 em。
                      value: s.paragraphGap,
                      min: 0,
                      max: 30,
                      divisions: 30,
                      format: (v) => v.round().toString(),
                      save: (v) => vm.change(
                        (s) => s.copyWith(paragraphGapEm: v / s.fontSize),
                      ),
                    ),
                    SettingsSlider(
                      labelStyle: GtText.body(context.gtColors.textPrimary)
                          .copyWith(fontSize: 14),
                      thumbRadius: GtSliderSize.thumbRadiusSmall,
                      trackThickness: GtSliderSize.trackThicknessSmall,
                      label: '页边距',
                      value: s.horizontalPadding,
                      min: 16,
                      max: 40,
                      divisions: 24,
                      format: (v) => v.round().toString(),
                      save: (v) =>
                          vm.change((s) => s.copyWith(horizontalPadding: v)),
                    ),

                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(height: 12),
                        Text(
                          '阅读主题',
                          style: GtText.body(context.gtColors.textPrimary)
                              .copyWith(fontSize: 14),
                        ),
                        const SizedBox(height: 8),
                        ReadingThemeCards(
                          selected: themeOf(current.themeId),
                          onSelect: (v) =>
                              saveSetting(context, () => vm.theme(v.name)),
                        ),
                      ],
                    ),
                  ][index],
                ),
              ),
      ),
    );
  }
}
