import 'package:taletin/ui/core/theme/gt_tokens.dart';
import 'package:taletin/ui/core/widgets/gt_switch.dart';
import 'package:taletin/ui/core/widgets/gt_app_bar.dart';
import 'package:taletin/ui/core/widgets/gt_dialog_action.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../view_models/global_reading_settings.dart';
import 'settings_action.dart';
import '../../../../domain/models/reading_settings.dart';
import 'settings_slider.dart';
import 'settings_row.dart';

class GlobalAutomaticNotifier extends AsyncNotifier<ReadingSettings> {
  @override
  Future<ReadingSettings> build() async =>
      (await ref.watch(globalSettingsProvider.future)).typography;
  Future<void> change({double? speed, int? seconds, bool? awake}) {
    return ref
        .read(globalSettingsProvider.notifier)
        .change(
          (s) => s.copyWith(
            autoScrollSpeed: speed,
            autoScanSeconds: seconds,
            autoKeepAwake: awake,
          ),
        );
  }
}

final globalAutomaticProvider =
    AsyncNotifierProvider<GlobalAutomaticNotifier, ReadingSettings>(
      GlobalAutomaticNotifier.new,
    );

class GlobalAutomaticDialog extends ConsumerWidget {
  const GlobalAutomaticDialog({super.key, this.asPage = false});
  final bool asPage;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(globalAutomaticProvider).value;
    final vm = ref.read(globalAutomaticProvider.notifier);
    final content = settings == null
        ? const SizedBox.shrink()
        : SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SettingsSlider(
                  thumbRadius: GtSliderSize.thumbRadiusLarge,
                  trackThickness: GtSliderSize.trackThicknessLarge,
                  label: '滚动速度（像素/秒）',
                  labelPosition: SliderLabelPosition.above,
                  value: settings.autoScrollSpeed,
                  min: 12,
                  max: 80,
                  divisions: 68,
                  format: (v) => v.round().toString(),
                  save: (v) => vm.change(speed: v),
                ),
                const SizedBox(height: 12),
                SettingsSlider(
                  thumbRadius: GtSliderSize.thumbRadiusLarge,
                  trackThickness: GtSliderSize.trackThicknessLarge,
                  label: '每页扫描耗时（秒）',
                  labelPosition: SliderLabelPosition.above,
                  value: settings.autoScanSeconds.toDouble(),
                  min: 2,
                  max: 30,
                  divisions: 28,
                  format: (v) => v.round().toString(),
                  save: (v) => vm.change(seconds: v.round()),
                ),
                const SizedBox(height: 12),
                SettingsRow(
                  divider: false,
                  label: '自动阅读时常亮',
                  trailing: GtSwitch(
                    value: settings.autoKeepAwake,
                    onChanged: (v) =>
                        saveSetting(context, () => vm.change(awake: v)),
                  ),
                ),
              ],
            ),
          );
    if (asPage) {
      return Scaffold(
        appBar: GtAppBar(title: const Text('自动阅读默认值')),
        body: SafeArea(
          child: Padding(padding: const EdgeInsets.all(20), child: content),
        ),
      );
    }
    return AlertDialog(
      title: const Text('自动阅读默认值'),
      content: content,
      actions: [
        GtDialogAction(
          role: GtDialogActionRole.primary,
          onPressed: () => Navigator.pop(context),
          label: '完成',
        ),
      ],
    );
  }
}
