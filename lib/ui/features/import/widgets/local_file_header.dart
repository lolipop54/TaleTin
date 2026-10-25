import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/theme/gt_tokens.dart';
import '../../../core/widgets/gt_button.dart';
import '../../../core/widgets/gt_icon.dart';
import '../view_models/local_files_view_model.dart';

class LocalFileHeader extends StatelessWidget {
  const LocalFileHeader({
    super.key,
    required this.state,
    required this.searching,
    required this.onBack,
    required this.onMode,
    required this.onSearch,
    required this.onQuery,
    required this.onSort,
    required this.onUp,
    required this.onRescan,
  });
  final LocalFilesState state;
  final bool searching;
  final VoidCallback onBack, onSearch, onUp;
  final VoidCallback onRescan;
  final ValueChanged<LocalFilesMode> onMode;
  final ValueChanged<String> onQuery;
  final ValueChanged<LocalFilesSort> onSort;
  @override
  Widget build(BuildContext context) {
    final colors = context.gtColors;
    return Column(
      children: [
        Container(
          constraints: const BoxConstraints(minHeight: GtSize.appBarHeight),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: colors.borderSubtle)),
          ),
          child: Row(
            children: [
              GtButton.icon(
                onPressed: onBack,
                icon: const GtIcon(GtIcons.arrowBack),
              ),
              Expanded(
                child: PopupMenuButton<LocalFilesMode>(
                  enabled: !state.busy,
                  onSelected: onMode,
                  itemBuilder: (_) => [
                    const PopupMenuItem(
                      value: LocalFilesMode.smart,
                      child: Text('智能导入'),
                    ),
                    const PopupMenuItem(
                      value: LocalFilesMode.folders,
                      child: Text('手机目录'),
                    ),
                  ],
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      minHeight: GtSize.touchMin,
                    ),
                    child: Row(
                      children: [
                        Flexible(
                          child: Text(
                            state.mode == LocalFilesMode.smart
                                ? '智能导入'
                                : '手机目录',
                            style: GtText.pageTitle(colors.textPrimary),
                          ),
                        ),
                        const GtIcon(GtIcons.caretDown),
                      ],
                    ),
                  ),
                ),
              ),
              GtButton.icon(
                key: const ValueKey('local-files-rescan'),
                tooltip: '重新扫描',
                onPressed: state.busy ? null : onRescan,
                // 循环图标的笔画范围比搜索/排序更满，略缩小以保持视觉大小一致。
                icon: const GtIcon(GtIcons.cycle, size: 22),
              ),
              GtButton.icon(
                onPressed: state.busy ? null : onSearch,
                icon: const GtIcon(GtIcons.search),
              ),
              PopupMenuButton<LocalFilesSort>(
                enabled: !state.busy,
                tooltip: '文件排序',
                onSelected: onSort,
                icon: GtIcon(GtIcons.filter, color: colors.textPrimary),
                itemBuilder: (_) => [
                  for (final sort in LocalFilesSort.values)
                    CheckedPopupMenuItem(
                      value: sort,
                      checked: state.sort == sort,
                      child: Text(sort.label),
                    ),
                ],
              ),
            ],
          ),
        ),
        if (searching)
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: GtSpacing.s5,
              vertical: GtSpacing.s2,
            ),
            child: TextField(
              autofocus: true,
              onChanged: onQuery,
              decoration: const InputDecoration(
                hintText: '搜索文件名',
                isDense: true,
              ),
            ),
          ),
        if (state.mode == LocalFilesMode.folders)
          Container(
            color: colors.subtle,
            padding: const EdgeInsets.only(left: GtSpacing.s5),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    state.path == null ? '手机存储' : '存储卡：${state.path}/',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GtText.body(colors.textMuted),
                  ),
                ),
                GtButton(
                  onPressed: state.busy || state.path == null ? null : onUp,
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      GtIcon(GtIcons.folderUp, size: GtSize.iconSmall),
                      SizedBox(width: GtSpacing.s1),
                      Text('上一级'),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
