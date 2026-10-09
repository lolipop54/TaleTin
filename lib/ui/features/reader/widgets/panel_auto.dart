import 'package:taletin/ui/core/widgets/gt_switch.dart';
import 'package:taletin/ui/core/widgets/gt_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/theme/gt_tokens.dart';
import '../view_models/reader_view_model.dart';
import '../view_models/reader_settings_view_model.dart';
import '../view_models/automatic_reading.dart';
import 'automatic_reading_speed.dart';
import '../../../core/widgets/book_loading.dart';
import 'reader_sheet.dart';

/// 自动阅读面板（参考图 03-5）。
/// 翻页方式沿用阅读设置，只在这里调整自动推进参数。
/// 开始前等待听书暂停，实际推进状态来自同一控制器。
class PanelAuto extends ConsumerWidget {
  const PanelAuto({super.key, required this.state, required this.bookId});

  final ReaderState state;
  final String bookId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final vm = ref.read(readerProvider.notifier);
    final colors = context.gtColors;
    final settings = ref.watch(readerSettingsProvider(bookId)).value?.settings;
    if (settings == null) return const Center(child: BookLoading());
    final preferences = ref.read(readerSettingsProvider(bookId).notifier);
    final automatic = ref.watch(automaticReadingProvider(bookId));
    final controller = ref.read(automaticReadingProvider(bookId).notifier);

    return ReaderSheet(
      title: '自动阅读',
      maxHeightFactor: 0.75,
      onClose: vm.closePanel,
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: GtSpacing.s5),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: GtSpacing.s2),
            // 开始自动阅读
            Row(
              children: [
                Expanded(child: Divider(color: colors.borderSubtle)),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: GtSpacing.s3),
                  child: GtButton.raw(
                    borderRadius: BorderRadius.circular(GtRadius.pill),
                    onPressed: automatic.preparing
                        ? null
                        : () => controller.hasSession
                              ? controller.discard()
                              : controller.start(),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: GtSpacing.s2,
                        vertical: GtSpacing.s2,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            controller.hasSession
                                ? Icons.stop
                                : Icons.play_arrow,
                            size: 26,
                            color: colors.actionPrimary,
                          ),
                          const SizedBox(width: GtSpacing.s2),
                          Text(
                            controller.hasSession ? '停止自动阅读' : '开始自动阅读',
                            style: GtText.body(colors.actionPrimary).copyWith(
                              fontSize: 16,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                Expanded(child: Divider(color: colors.borderSubtle)),
              ],
            ),
            const SizedBox(height: GtSpacing.s3),
            AutomaticReadingSpeed(
              settings: settings,
              onScrollSpeed: preferences.setAutoScrollSpeed,
              onScanSeconds: preferences.setAutoScanSeconds,
              pendingSave: () => preferences.pendingWrites,
            ),
            const SizedBox(height: GtSpacing.s2),
            Container(height: 1, color: colors.borderSubtle),
            const SizedBox(height: GtSpacing.s2),
            // 屏幕常亮
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '屏幕常亮',
                        style: GtText.body(colors.textPrimary)
                            .copyWith(fontSize: 14),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '自动阅读期间保持屏幕常亮',
                        style: GtText.caption(colors.textMuted)
                            .copyWith(fontSize: 12),
                      ),
                    ],
                  ),
                ),
                GtSwitch(
                  value: settings.autoKeepAwake,
                  onChanged: preferences.setAutoKeepAwake,
                ),
              ],
            ),
            const SizedBox(height: GtSpacing.s4),
          ],
        ),
      ),
    );
  }
}
