import 'package:taletin/ui/core/widgets/gt_switch.dart';
import 'package:taletin/ui/core/widgets/gt_button.dart';
import 'package:flutter/material.dart';

import '../../../../app/router/main_pages_ready.dart';
import '../../../../app/di/theme_providers.dart';
import '../../../../app/di/reading_controls_providers.dart';
import '../../../../app/di/app_font_providers.dart';
import '../../../../app/di/statistics_settings_providers.dart';
import '../../../../domain/repositories/app_theme_repository.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../domain/models/reading_settings.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/theme/gt_tokens.dart';
import '../../../core/widgets/decorations.dart';
import '../view_models/settings_view_model.dart';
import '../widgets/global_automatic_dialog.dart';
import '../widgets/settings_action.dart';
import '../widgets/settings_page.dart';
import '../view_models/global_reading_settings.dart';
import '../view_models/backup_view_model.dart';
import '../../achievements/view_models/notes_providers.dart';
import '../../../core/widgets/state_views.dart';
import 'global_typography_view.dart';
import 'statistics_settings_view.dart';
import 'storage_view.dart';
import 'about_view.dart';
import 'backup_view.dart';
import 'restore_view.dart';
import 'notes_export_view.dart';
import '../../reader/view_models/listening_view_state.dart';
import 'listening_rate_view.dart';
import '../../reader/view_models/listening_panel_view_model.dart';
import '../../reader/view_models/listening_voice_choices.dart';
import 'listening_voice_view.dart';
import '../widgets/settings_row.dart';

/// 设置页（参考图 05）。
/// 分区：外观 / 阅读 / 听书 / 数据 / 关于；统一行高与左右边缘。
class SettingsView extends ConsumerWidget {
  const SettingsView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    MainPagesReady.dependOn(context);
    final colors = context.gtColors;
    final voices = ref.watch(listeningVoicesProvider);
    final speech = ref.watch(listeningViewStateProvider).value;
    // 全局默认排版模式；还没读出来时不显示值（也不可点）
    final layoutMode = ref.watch(globalLayoutModeProvider).value;
    final pageTurn = ref.watch(globalPageTurnProvider).value;
    final controls = ref.watch(readingControlsProvider).value;
    final status = ref.watch(statusInfoVisibleProvider);
    // 第一屏依赖的偏好一起准备，刷新时 AsyncValue 保留上一份值。
    if (layoutMode == null ||
        pageTurn == null ||
        controls == null ||
        !status.hasValue ||
        (!voices.hasValue && voices.isLoading) ||
        speech == null) {
      final failed =
          ref.watch(globalSettingsProvider).hasError ||
          ref.watch(readingControlsProvider).hasError ||
          status.hasError;
      return Scaffold(
        body: failed
            ? GtErrorView(
                title: '设置读取失败',
                onRetry: () {
                  ref.invalidate(globalSettingsProvider);
                  ref.invalidate(readingControlsProvider);
                  ref.invalidate(statusInfoVisibleProvider);
                },
              )
            : const SizedBox.shrink(),
      );
    }

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: EdgeInsets.fromLTRB(
            GtSpacing.s5,
            GtSpacing.s5,
            GtSpacing.s5,
            // 只增加列表末尾留白，滚动途中仍可从底栏凹口看到设置项。
            GtSpacing.s6 + MediaQuery.paddingOf(context).bottom,
          ),
          children: [
            _buildHeader(context, colors),
            const SizedBox(height: GtSpacing.s4),
            _sectionHeader(context, '外观'),
            SettingsRow(
              label: '主题',
              value: ref.watch(appThemeProvider).label,
              onTap: () async {
                await openSettingsPage(
                  context,
                  SettingsChoices<AppThemeMode>(
                    title: '应用主题',
                    options: AppThemeMode.values,
                    label: (v) => v.label,
                    selected: (ref) => ref.watch(appThemeProvider),
                    save: (ref, v) =>
                        ref.read(appThemeProvider.notifier).select(v),
                  ),
                );
              },
            ),
            const SizedBox(height: GtSpacing.s4),
            _sectionHeader(context, '阅读'),
            SettingsRow(
              label: '字体与排版',
              onTap: () => openSettingsPage(
                context,
                const GlobalTypographyView(),
                ready: currentTypographyFontsProvider.future,
              ),
            ),
            SettingsRow(
              label: '翻页方式',
              value: pageTurn.label,
              onTap: () => openSettingsPage(
                context,
                SettingsChoices<PageTurnEffect>(
                  title: '翻页方式',
                  options: PageTurnEffect.values,
                  label: (v) => v.label,
                  selected: (ref) => ref
                      .watch(globalSettingsProvider)
                      .requireValue
                      .typography
                      .pageTurnEffect,
                  save: (ref, v) =>
                      ref.read(globalPageTurnProvider.notifier).select(v),
                ),
              ),
            ),
            SettingsRow(
              label: '自动阅读默认值',
              onTap: () => openSettingsPage(
                context,
                const GlobalAutomaticDialog(asPage: true),
                ready: globalAutomaticProvider.future,
              ),
            ),
            SettingsRow(
              label: '显示状态信息',
              // 关掉后阅读页不再画顶部章节信息与底部时间/电量
              trailing: GtSwitch(
                value: status.requireValue,
                onChanged: (_) => saveSetting(
                  context,
                  () => ref.read(statusInfoVisibleProvider.notifier).toggle(),
                ),
              ),
            ),
            SettingsRow(
              label: '显示系统顶部状态栏',
              trailing: GtSwitch(
                value: controls.statusBar,
                onChanged: (v) => saveSetting(
                  context,
                  () => ref
                      .read(readingControlsProvider.notifier)
                      .change(statusBar: v),
                ),
              ),
            ),
            SettingsRow(
              label: '显示系统底部导航栏',
              trailing: GtSwitch(
                value: controls.navigationBar,
                onChanged: (v) => saveSetting(
                  context,
                  () => ref
                      .read(readingControlsProvider.notifier)
                      .change(navigationBar: v),
                ),
              ),
            ),
            SettingsRow(
              label: '阅读时屏幕常亮',
              trailing: GtSwitch(
                value: controls.keepAwake,
                onChanged: (v) => saveSetting(
                  context,
                  () => ref
                      .read(readingControlsProvider.notifier)
                      .change(awake: v),
                ),
              ),
            ),
            SettingsRow(
              label: '音量键翻页',
              trailing: GtSwitch(
                value: controls.volumeKeys,
                onChanged: (v) => saveSetting(
                  context,
                  () => ref
                      .read(readingControlsProvider.notifier)
                      .change(keys: v),
                ),
              ),
            ),
            const SizedBox(height: GtSpacing.s4),
            _sectionHeader(context, '听书'),
            if (!voices.hasValue)
              GtButton(
                onPressed: () => ref.invalidate(listeningVoicesProvider),
                child: const Text('音色准备失败，点击重试'),
              )
            else ...[
              if (speech.error != null) Text(speech.error!),
              SettingsRow(
                label: '引擎与离线音色',
                value: speech.voice == null
                    ? '未选择'
                    : '${speech.voice!.displayName} · ${speech.voice!.locale}',
                onTap: () => openSettingsPage(
                  context,
                  const ListeningVoiceView(),
                  ready: listeningVoiceChoicesProvider.future,
                ),
              ),
              SettingsRow(
                label: '语速',
                value: '${speech.speed.toStringAsFixed(1)}×',
                onTap: () =>
                    openSettingsPage(context, const ListeningRateView()),
              ),
            ],
            const SizedBox(height: GtSpacing.s4),
            _sectionHeader(context, '数据'),
            SettingsRow(
              label: '阅读统计设置',
              onTap: () => openSettingsPage(
                context,
                const StatisticsSettingsView(),
                ready: statisticsSettingsProvider.future,
              ),
            ),
            SettingsRow(
              label: '存储占用',
              onTap: () => openSettingsPage(context, const StorageView()),
            ),
            SettingsRow(
              label: '导出备份',
              onTap: () => openSettingsPage(
                context,
                const BackupView(),
                ready: savedBackupsProvider.future,
              ),
            ),
            SettingsRow(
              label: '恢复备份',
              onTap: () => openSettingsPage(context, const RestoreView()),
            ),
            SettingsRow(
              label: '导出阅读笔记',
              onTap: () => openSettingsPage(
                context,
                const NotesExportView(),
                ready: annotatedBooksProvider.future,
              ),
            ),
            const SizedBox(height: GtSpacing.s4),
            _sectionHeader(context, '关于'),
            const SettingsRow(label: '支持格式', value: 'EPUB · TXT'),
            SettingsRow(
              label: '版本、许可与隐私',
              onTap: () => openSettingsPage(
                context,
                const AboutView(),
                ready: appInformationProvider.future,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 页头：设置 + 蓝折角装饰 + 副标题 + 右侧竖排落款。
  Widget _buildHeader(BuildContext context, GtColors colors) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                // 折角与标题顶部对齐，读起来是标题块右上角的折角
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '设置',
                    style: GtText.pageTitle(colors.textPrimary)
                        .copyWith(fontSize: 25),
                  ),
                  const SizedBox(width: GtSpacing.s2),
                  const Padding(
                    padding: EdgeInsets.only(top: 3),
                    child: FoldCorner(height: 21),
                  ),
                ],
              ),
              const SizedBox(height: GtSpacing.s1),
              Text(
                '阅读，让生活更柔软。',
                style: GtText.body(colors.textSecondary)
                    .copyWith(fontSize: 14, letterSpacing: 1),
              ),
            ],
          ),
        ),
        const SizedBox(width: GtSpacing.s3),
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            // 右侧落款是横排两行、右对齐（参考图 05）
            Text(
              '书中自有',
              style: GtText.caption(colors.textSecondary)
                  .copyWith(fontSize: 11, height: 1.7),
            ),
            Text(
              '向上的光',
              style: GtText.caption(colors.textSecondary)
                  .copyWith(fontSize: 11, height: 1.7),
            ),
            const SizedBox(height: GtSpacing.s2),
            Container(width: 18, height: 1, color: colors.borderControl),
          ],
        ),
      ],
    );
  }

  /// 分区头只保留名称和原有小折角。
  Widget _sectionHeader(BuildContext context, String title) {
    final colors = context.gtColors;
    return Padding(
      padding: const EdgeInsets.only(bottom: GtSpacing.s1),
      child: Row(
        // 折角贴着分区标题的顶部
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: GtText.sectionTitle(colors.textPrimary)
                .copyWith(fontSize: 19),
          ),
          const SizedBox(width: GtSpacing.s2),
          const Padding(
            padding: EdgeInsets.only(top: 2),
            child: FoldCorner(height: 19),
          ),
        ],
      ),
    );
  }
}
