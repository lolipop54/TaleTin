import 'package:flutter/material.dart';

import '../../../../domain/services/local_book_files.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/gt_tokens.dart';
import '../../../core/widgets/gt_button.dart';
import '../../../core/widgets/gt_icon.dart';
import '../view_models/local_files_view_model.dart';

/// 分组与条目拍平后懒加载；文件名可换行，长书名不会把右侧勾选框挤走。
class LocalFileList extends StatelessWidget {
  const LocalFileList({super.key, required this.state, required this.onTap,
    required this.onImport, this.importing = const {}});
  final LocalFilesState state;
  final ValueChanged<LocalBookEntry> onTap;
  final ValueChanged<LocalBookEntry> onImport;
  final Set<String> importing;
  @override
  Widget build(BuildContext context) {
    final colors = context.gtColors;
    final rows = <Object>[];
    String? previous;
    final now = DateTime.now();
    for (final entry in state.visible) {
      final days = now.difference(entry.modified).inDays;
      final group = entry.directory ? '文件夹' : state.sort == LocalFilesSort.time
          ? (days < 7
                ? '一周以内'
                : days < 30
                ? '一月以内'
                : '一月以前')
          : state.sort == LocalFilesSort.name ? entry.initial : '文件';
      if (group != previous) {
        rows.add(group);
        previous = group;
      }
      rows.add(entry);
    }
    return ListView.builder(
      key: PageStorageKey('${state.mode}/${state.path}'),
      padding: const EdgeInsets.symmetric(horizontal: GtSpacing.s5),
      itemCount: rows.length,
      itemBuilder: (context, index) {
        final row = rows[index];
        if (row is String) {
          return Container(
            padding: const EdgeInsets.symmetric(vertical: GtSpacing.s2),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: colors.borderSubtle)),
            ),
            child: Text(row, style: GtText.body(colors.textMuted)),
          );
        }
        final entry = row as LocalBookEntry;
        final selected = state.selected.containsKey(entry.path);
        final imported = state.imported.contains(entry.path);
        final queued = importing.contains(entry.document.uri);
        return Container(
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: colors.borderSubtle)),
          ),
          child: GtButton.raw(
            onPressed: imported || queued ? null : () =>
              entry.directory ? onTap(entry) : onImport(entry),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: GtSpacing.s3),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          entry.title,
                          style: GtText.importFileName(colors.textPrimary),
                        ),
                        const SizedBox(height: GtSpacing.s1),
                        if (entry.directory)
                          Text(
                            entry.count < 0 ? '手机存储' : '${entry.count} 项',
                            style: GtText.body(colors.textMuted),
                          )
                        else
                          Wrap(
                            spacing: GtSpacing.s2,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: GtSpacing.s1,
                                ),
                                decoration: BoxDecoration(
                                  color: entry.extension == 'epub'
                                      ? colors.success
                                      : colors.actionPrimary,
                                  borderRadius: BorderRadius.circular(
                                    GtRadius.cover,
                                  ),
                                ),
                                child: Text(
                                  entry.extension.toUpperCase(),
                                  style: GtText.caption(colors.onPrimary),
                                ),
                              ),
                              Text(
                                _size(entry.size),
                                style: GtText.body(colors.textMuted),
                              ),
                              if (state.mode == LocalFilesMode.smart)
                                Text(
                                  _date(entry.modified),
                                  style: GtText.body(colors.textMuted),
                                ),
                            ],
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: GtSpacing.s4),
                  SizedBox(
                    width: imported || queued ? GtSize.touchMin + GtSpacing.s4 : GtSize.touchMin,
                    child: Center(
                      child: entry.directory
                          ? GtIcon(
                              GtIcons.folder,
                              color: colors.warning,
                              size: GtSize.iconNormal + GtSpacing.s2,
                            )
                          : imported || queued
                          ? Text(imported ? '已导入' : '导入中', style: GtText.caption(colors.textMuted).copyWith(fontSize: 14))
                          : GtButton.raw(
                            key: ValueKey('select:${entry.path}'),
                            onPressed: () => onTap(entry),
                            child: SizedBox.square(dimension: GtSize.touchMin,
                            child: Center(child: GtIcon(
                              selected
                                  ? GtIcons.checkboxSelected
                                  : GtIcons.checkbox,
                              size: GtSize.iconNormal,
                              color: selected
                                  ? colors.actionPrimary
                                  : colors.textSecondary,
                            ))),
                          ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  String _date(DateTime date) =>
      '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  String _size(int bytes) => bytes >= 1024 * 1024
      ? '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB'
      : bytes >= 1024
      ? '${(bytes / 1024).toStringAsFixed(1)}KB'
      : '${bytes}B';
}
