import '../../bookshelf/widgets/book_cover_sheet.dart';

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';

import '../../../../app/export_error_log.dart';
import '../../../../app/di/theme_providers.dart';
import '../../../../app/di/statistics_settings_providers.dart';
import '../../../../domain/repositories/app_theme_repository.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/theme/gt_tokens.dart';
import '../../../core/widgets/decorations.dart';
import '../widgets/settings_heading.dart';
import '../widgets/settings_page.dart';
import '../widgets/windows_settings_layout.dart';
import '../view_models/storage_view_model.dart';
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
import 'changelog_view.dart';
import 'restore_view.dart';
import 'notes_export_view.dart';
import '../widgets/settings_row.dart';

/// 设置页（参考图 05）。
/// 分区：外观 / 阅读 / 数据 / 关于；统一行高与左右边缘。
class SettingsView extends ConsumerWidget {
  const SettingsView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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

    final theme = ref.watch(appThemeProvider);
    if (defaultTargetPlatform == TargetPlatform.windows) {
      return WindowsSettingsLayout(
        entries: (context, category) => _entries(context, ref, category, theme),
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
            const SettingsHeader(titleSize: 25),
            for (final category in SettingsCategory.values) ...[
              const SizedBox(height: GtSpacing.s4),
              _sectionHeader(context, category.label),
              ..._entries(context, ref, category, theme),
            ],
          ],
        ),
      ),
    );
  }

  List<Widget> _entries(
    BuildContext context,
    WidgetRef ref,
    SettingsCategory category,
    AppThemeMode theme,
  ) => switch (category) {
    SettingsCategory.appearance => [
      SettingsRow(
        label: '主题',
        value: theme.label,
        onTap: () => openSettingsPage(
          context,
          SettingsChoices<AppThemeMode>(
            title: '应用主题',
            options: AppThemeMode.values,
            label: (mode) => mode.label,
            selected: (ref) => ref.watch(appThemeProvider),
            save: (ref, mode) =>
                ref.read(appThemeProvider.notifier).select(mode),
          ),
        ),
      ),
      SettingsRow(
        label: '自定义封面',
        onTap: () => WindowsSettingsPane.contains(context)
            ? openSettingsPage(
                context,
                prepareBookCoverSheet(
                  context,
                  ref,
                  const [],
                  global: true,
                  width: WindowsSettingsPane.detailWidth(
                    context,
                    Navigator.of(context).context.size!.width,
                  ),
                ),
              )
            : showBookCoverSheet(context, ref, const [], global: true),
      ),
    ],
    SettingsCategory.reading => [
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
    ],
    SettingsCategory.data => [
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
        onTap: () => openSettingsPage(
          context,
          const StorageView(),
          ready: WindowsSettingsPane.contains(context)
              ? storageUsageProvider.future
              : null,
        ),
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
    ],
    SettingsCategory.about => [
      SettingsRow(
        label: '支持格式',
        value: 'EPUB · TXT · MOBI · AZW3 · PDF',
        wrapValue: WindowsSettingsPane.contains(context),
      ),
      SettingsRow(
        label: '更新日志',
        onTap: () => openSettingsPage(
          context,
          const ChangelogView(),
          ready: changelogProvider.future,
        ),
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
  };

  /// 分区头只保留名称和原有小折角。
  Widget _sectionHeader(BuildContext context, String title) {
    final colors = context.gtColors;
    return Padding(
      padding: const EdgeInsets.only(bottom: GtSpacing.s1),
      child: FoldCornerHeading(
        title,
        style: GtText.sectionTitle(colors.textPrimary).copyWith(fontSize: 19),
      ),
    );
  }
}
