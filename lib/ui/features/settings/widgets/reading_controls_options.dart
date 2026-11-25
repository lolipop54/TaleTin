import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forui/forui.dart';

import '../../../../domain/repositories/reading_controls_repository.dart';

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
  const ReadingControlsOptions({
    super.key,
    this.includeKeepAwake = true,
    this.includePdfFixedViewMode = true,
  });

  final bool includeKeepAwake;
  final bool includePdfFixedViewMode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controls = ref.watch(readingControlsProvider).value;
    final status = ref.watch(statusInfoVisibleProvider).value;
    if (controls == null || status == null) return const SizedBox.shrink();
    final vm = ref.read(readingControlsProvider.notifier);
    final mobileControls = defaultTargetPlatform != TargetPlatform.windows;
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
        SettingsRow(
          divider: false,
          label: '阅读进度样式',
          trailing: _ProgressStyleSelect(
            value: controls.progressStyle,
            onChanged: (value) =>
                saveSetting(context, () => vm.change(progressStyle: value)),
          ),
        ),
        option(
          '显示状态信息',
          status,
          (_) => ref.read(statusInfoVisibleProvider.notifier).toggle(),
        ),
        if (mobileControls) ...[
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
          option(
            '音量键翻页',
            controls.volumeKeys,
            (value) => vm.change(keys: value),
          ),
        ],
        if (includePdfFixedViewMode)
          option(
            '固定视图模式',
            controls.pdfFixedViewMode,
            (value) => vm.change(pdfFixedViewMode: value),
          ),
        if (mobileControls)
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

class _ProgressStyleSelect extends StatelessWidget {
  const _ProgressStyleSelect({required this.value, required this.onChanged});

  final ReadingProgressStyle value;
  final ValueChanged<ReadingProgressStyle> onChanged;

  static String _label(ReadingProgressStyle style) => switch (style) {
    ReadingProgressStyle.percentage => '百分比',
    ReadingProgressStyle.pages => '页码',
  };

  @override
  Widget build(BuildContext context) {
    final field = context.theme.selectStyle.fieldStyles.sm;
    final labelStyle = field.contentTextStyle.resolve({}).copyWith(
      fontSize: 12,
      height: 1,
      leadingDistribution: TextLeadingDistribution.even,
    );
    final compact = field.copyWith(
      constraints: const BoxConstraints(minHeight: 30),
      contentPadding: const EdgeInsetsGeometryDelta.value(
        EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      ),
      contentTextStyle: FVariants.all(labelStyle),
      // 输入框也用隐藏提示的基线排版。字号不同时，放大系统文字会把当前值推低。
      hintTextStyle: FVariants.all(labelStyle),
      border: FVariants.all(field.border.resolve({})),
    );
    final scaler = MediaQuery.textScalerOf(context);
    // 按最长的三个中文字预留宽度，系统放大字号时按钮随之变宽。
    final width = 42 + 3 * scaler.scale(12);
    // 面板的 MediaQuery 只有面板大小；菜单画在根浮层，避让边缘时也要用整窗尺寸。
    return MediaQuery.fromView(
      view: View.of(context),
      child: SizedBox(
        width: width,
        child: FSelect<ReadingProgressStyle>.rich(
          format: _label,
          control: FSelectControl.lifted(
            value: value,
            onChange: (next) {
              if (next != null) onChanged(next);
            },
          ),
          // 中文笔画中心比行框中心稍低，在框内余量中略向上对齐。
          textAlignVertical: const TextAlignVertical(y: -0.08),
          // 外层最小高度只约束点击区域，箭头也要撑起可见边框。
          suffixBuilder: (context, style, variants) => SizedBox(
            height: 30,
            child: Center(
              widthFactor: 1,
              child: FSelect.defaultIconBuilder(context, style, variants),
            ),
          ),
          style: FSelectStyleDelta.delta(
            fieldStyles: FVariants.all(compact),
            contentStyle: const FSelectContentStyleDelta.delta(
              padding: EdgeInsetsGeometryDelta.value(
                EdgeInsets.symmetric(vertical: 3),
              ),
            ),
          ),
          mouseCursor: SystemMouseCursors.click,
          fieldAnchor: Alignment.bottomRight,
          contentAnchor: Alignment.topRight,
          contentOverlayLocation: OverlayChildLocation.rootOverlay,
          contentConstraints: FPortalConstraints.tightFor(width: width + 8),
          children: [
            for (final option in ReadingProgressStyle.values)
              FSelectItem<ReadingProgressStyle>(
                value: option,
                title: Center(
                  child: Text(
                    _label(option),
                    style: const TextStyle(fontSize: 12, height: 1),
                  ),
                ),
                suffixBuilder: (_, _) => null,
                style: FItemStyleDelta.delta(
                  // 默认会在标题右边给后缀留一段间距，纯文字选项要左右对称。
                  contentStyle: const FItemContentStyleDelta.delta(
                    middleSpacing: 0,
                    unsuffixedPadding: EdgeInsetsGeometryDelta.value(
                      EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                    ),
                  ),
                  contentDecoration: option == value
                      ? FVariants.all(
                          ShapeDecoration(
                            shape: RoundedSuperellipseBorder(
                              borderRadius: context.theme.style.borderRadius.md,
                            ),
                            color: context.theme.colors.secondary,
                          ),
                        )
                      : null,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
