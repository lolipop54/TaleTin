import 'package:taletin/ui/core/widgets/gt_switch.dart';
import 'package:taletin/ui/core/widgets/gt_app_bar.dart';
import 'package:taletin/ui/core/widgets/gt_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/di/app_providers.dart';
import '../../../../app/di/app_font_providers.dart';
import '../../../../domain/models/reading_settings.dart';
import '../view_models/global_reading_settings.dart';
import '../widgets/settings_action.dart';
import '../widgets/settings_row.dart';
import '../widgets/settings_page.dart';
import 'global_font_view.dart';

/// 保留全局排版模式、字体与显示方式；细节在阅读器控制面板调整。
class GlobalTypographyView extends ConsumerWidget {
  const GlobalTypographyView({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(globalSettingsProvider);
    final fonts = ref.watch(currentTypographyFontsProvider).value;
    final current = data.value;
    final vm = ref.read(globalSettingsProvider.notifier);
    void change(ReadingSettings Function(ReadingSettings) update) =>
        saveSetting(context, () => vm.change(update));
    return Scaffold(
      appBar: GtAppBar(title: const Text('全局字体与排版')),
      body: SafeArea(
        child: current == null || fonts == null
            ? Center(
                child: data.hasError
                    ? GtButton(
                        onPressed: () {
                          ref.invalidate(globalSettingsProvider);
                        },
                        child: const Text('读取失败，点击重试'),
                      )
                    : const SizedBox.shrink(),
              )
            : ListView.separated(
                padding: const EdgeInsets.all(20),
                separatorBuilder: (context, index) => const SizedBox(height: 8),
                itemCount: ReadingLayoutMode.originalIncluded ? 5 : 4,
                itemBuilder: (context, index) {
                  final s = current.typography;
                  return [
                    if (ReadingLayoutMode.originalIncluded)
                      SettingsRow(
                        divider: false,
                        label: '排版模式',
                        value: s.layoutMode.isOriginal ? '原书排版' : '简化排版',
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
                  ][index];
                },
              ),
      ),
    );
  }
}
