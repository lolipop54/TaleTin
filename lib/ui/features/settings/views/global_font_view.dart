import 'package:taletin/core/diagnostics/app_errors.dart';
import 'package:taletin/ui/core/widgets/gt_switch.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/di/app_providers.dart';
import '../../../../domain/models/reading_settings.dart';
import '../widgets/font_choices.dart';
import '../view_models/global_reading_settings.dart';
import '../widgets/settings_page.dart';
import '../widgets/settings_row.dart';

/// 原书字体只在原书模式下参与选择；旧字体别名沿用正文的解析规则。
String globalFontChoice(ReadingSettings settings) =>
    selectedFontChoice(settings);

/// 进入前已经加载字体文件和名称；纵向列表随名称长度增高，不截断预览。
class GlobalFontView extends ConsumerWidget {
  const GlobalFontView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(globalSettingsProvider).requireValue.typography;
    final fonts = ref.watch(fontFamilyNamesProvider).requireValue;
    final choices = readingFontChoices(settings, fonts);
    return SettingsChoices<String>(
      title: '字体',
      leading: SettingsRow(
        label: '仅阅读页应用',
        trailing: GtSwitch(
          value: settings.fontOnlyInReader,
          onChanged: (value) async {
            try {
              await ref
                  .read(globalSettingsProvider.notifier)
                  .change(
                    (current) => current.copyWith(fontOnlyInReader: value),
                  );
            } catch (appError, appStack) {
              AppErrors.report(appError, appStack, operation: '全局字体未保存', notify: false);
              if (context.mounted) {
                AppErrors.report(appError, appStack, operation: '全局字体未保存');
              }
            }
          },
        ),
      ),
      options: choices.keys.toList(),
      label: (id) => choices[id]!,
      optionStyle: (id, active) => fontChoiceStyle(context, id, active),
      selected: (ref) => globalFontChoice(
        ref.watch(globalSettingsProvider).requireValue.typography,
      ),
      save: (ref, id) => ref
          .read(globalSettingsProvider.notifier)
          .change(
            (current) => id == '__original'
                ? current.copyWith(useOriginalFont: true)
                : current.copyWith(fontFamily: id, useOriginalFont: false),
          ),
    );
  }
}
