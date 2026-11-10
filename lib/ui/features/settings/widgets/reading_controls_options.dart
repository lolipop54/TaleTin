import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/di/reading_controls_providers.dart';
import '../../../core/widgets/gt_switch.dart';
import '../view_models/settings_view_model.dart';
import 'settings_action.dart';
import 'settings_row.dart';

/// 打开子页前一起读好开关，避免先显示默认值再跳到保存值。
final readingControlsReadyProvider = FutureProvider<void>((ref) async {
  await Future.wait([
    ref.watch(readingControlsProvider.future),
    ref.watch(statusInfoVisibleProvider.future),
  ]);
});

/// 设置页与阅读面板共用全局开关；阅读面板的常亮入口放在亮度面板。
class ReadingControlsOptions extends ConsumerWidget {
  const ReadingControlsOptions({super.key, this.includeKeepAwake = true});

  final bool includeKeepAwake;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controls = ref.watch(readingControlsProvider).value;
    final status = ref.watch(statusInfoVisibleProvider).value;
    if (controls == null || status == null) return const SizedBox.shrink();
    final vm = ref.read(readingControlsProvider.notifier);
    Widget option(
      String label,
      bool value,
      Future<void> Function(bool) save, {
      String? subtitle,
    }) => SettingsRow(
      divider: false,
      label: label,
      subtitle: subtitle,
      trailing: GtSwitch(
        value: value,
        onChanged: (next) => saveSetting(context, () => save(next)),
      ),
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        option(
          '显示状态信息',
          status,
          (_) => ref.read(statusInfoVisibleProvider.notifier).toggle(),
        ),
        option(
          '显示系统顶部状态栏',
          controls.statusBar,
          (value) => vm.change(statusBar: value),
        ),
        option(
          '显示系统底部导航栏',
          controls.navigationBar,
          (value) => vm.change(navigationBar: value),
        ),
        if (includeKeepAwake)
          option(
            '阅读时屏幕常亮',
            controls.keepAwake,
            (value) => vm.change(awake: value),
          ),
        option('音量键翻页', controls.volumeKeys, (value) => vm.change(keys: value)),
        option(
          '底部上滑退出',
          controls.swipeUpToExit,
          (value) => vm.change(swipeUpToExit: value),
          subtitle: '滚动模式为左滑退出',
        ),
      ],
    );
  }
}
