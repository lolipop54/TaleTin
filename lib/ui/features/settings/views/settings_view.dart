import '../../bookshelf/widgets/book_cover_sheet.dart';

import 'package:flutter/material.dart';

import '../../../../app/export_error_log.dart';
import '../../../../app/di/theme_providers.dart';
import '../../../../app/di/statistics_settings_providers.dart';
import '../../../../domain/repositories/app_theme_repository.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/theme/gt_tokens.dart';
import '../../../core/widgets/decorations.dart';
import '../widgets/settings_page.dart';
import '../view_models/global_reading_settings.dart';
import '../view_models/backup_view_model.dart';
import '../../achievements/view_models/notes_providers.dart';
import '../../../core/widgets/state_views.dart';
import 'global_typography_view.dart';
import 'reading_more_settings_view.dart';
import '../widgets/reading_controls_options.dart';
import '../view_models/reading_backgrounds.dart';
import 'statistics_settings_view.dart';
import 'storage_view.dart';
import 'about_view.dart';
import 'backup_view.dart';
import 'restore_view.dart';
import 'notes_export_view.dart';
import '../widgets/settings_row.dart';

/// 设置页（参考图 05）。
/// 分区：外观 / 阅读 / 数据 / 关于；统一行高与左右边缘。
class SettingsView extends ConsumerWidget {
  const SettingsView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.gtColors;
    final settings = ref.watch(globalSettingsProvider);
    if (!settings.hasValue) {
      return Scaffold(
        body: settings.hasError
            ? GtErrorView(
                title: '设置读取失败',
                onRetry: () => ref.invalidate(globalSettingsProvider),
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
            SettingsRow(
              label: '自定义封面',
              onTap: () =>
                  showBookCoverSheet(context, ref, const [], global: true),
            ),
            const SizedBox(height: GtSpacing.s4),
            _sectionHeader(context, '阅读'),
            SettingsRow(
              label: '字体与排版',
              onTap: () => openSettingsPage(
                context,
                const GlobalTypographyView(),
                ready: globalTypographyReadyProvider.future,
              ),
            ),
            SettingsRow(
              label: '更多设置',
              onTap: () => openSettingsPage(
                context,
                const ReadingMoreSettingsView(),
                ready: readingControlsReadyProvider.future,
              ),
            ),
            const SizedBox(height: GtSpacing.s4),
            _sectionHeader(context, '数据'),
            SettingsRow(label: '导出错误日志', onTap: exportErrorLog),
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
            const SettingsRow(
              label: '支持格式',
              value: 'EPUB · TXT · MOBI · AZW3 · PDF',
            ),
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
