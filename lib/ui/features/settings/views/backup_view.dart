import 'package:taletin/ui/core/widgets/gt_app_bar.dart';
import 'package:taletin/ui/core/widgets/gt_button.dart';
import 'package:taletin/ui/core/widgets/gt_dialog_action.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../domain/use_cases/delete_books.dart' show formatBytes;
import '../../../../platform/channels/system_toast.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/gt_tokens.dart';
import '../view_models/backup_view_model.dart';
import '../widgets/settings_progress.dart';

class BackupView extends ConsumerWidget {
  const BackupView({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(backupViewProvider);
    final vm = ref.read(backupViewProvider.notifier);
    final manifest = state.snapshot?.manifest;
    final saved = ref.watch(savedBackupsProvider);
    final c = context.gtColors;
    // 操作结果用短提示，不在按钮之间临时插入文字。
    ref.listen(backupViewProvider, (previous, next) {
      if (previous?.busy == true && !next.busy && next.message.isNotEmpty) {
        SystemToast.show(next.message).ignore();
      }
    });
    Widget card(Widget child) => Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(GtRadius.card),
        border: Border.all(color: c.borderSubtle),
      ),
      child: child,
    );
    return PopScope(
      canPop: !state.busy,
      child: Scaffold(
        appBar: GtAppBar(title: const Text('导出备份')),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Text(
                '备份书籍、笔记、阅读进度、统计、成就和设置。恢复数据前会自动保留一份当前书库快照。',
                style: GtText.body(c.textSecondary),
              ),
              const SizedBox(height: 16),
              card(
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('书库备份', style: GtText.sectionTitle(c.textPrimary)),
                    const SizedBox(height: 12),
                    if (manifest != null) ...[
                      Wrap(
                        spacing: 12,
                        runSpacing: 4,
                        children: [
                          Text(
                            '${manifest.bookCount} 本书',
                            style: GtText.sectionTitle(c.textPrimary),
                          ),
                          Text(
                            formatBytes(manifest.totalBytes),
                            style: GtText.body(c.textSecondary),
                          ),
                        ],
                      ),
                      Text(
                        manifest.createdAt
                            .toLocal()
                            .toString()
                            .split('.')
                            .first,
                        style: GtText.caption(c.textSecondary),
                      ),
                      const SizedBox(height: 12),
                    ],
                    if (state.busy) ...[
                      SettingsProgress(
                        label: state.message,
                        fraction: state.total > 0
                            ? state.done / state.total
                            : null,
                      ),
                      const SizedBox(height: 12),
                    ],
                    GtButton.outlined(
                      onPressed: state.busy ? null : vm.prepare,
                      child: Text(manifest == null ? '准备备份' : '重新准备备份'),
                    ),
                    const SizedBox(height: 8),
                    GtButton.filled(
                      onPressed: state.busy || manifest == null
                          ? null
                          : vm.save,
                      child: const Text('选择位置并保存'),
                    ),
                    if (state.busy && state.canCancel)
                      GtButton(onPressed: vm.cancel, child: const Text('取消操作')),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              card(
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('恢复前自动快照', style: GtText.sectionTitle(c.textPrimary)),
                    const SizedBox(height: 8),
                    if (saved.hasError)
                      GtButton(
                        onPressed: () => ref.invalidate(savedBackupsProvider),
                        child: const Text('读取失败，点击重试'),
                      ),
                    if (saved.value case final snapshots?) ...[
                      if (snapshots.isEmpty)
                        Text('暂无快照', style: GtText.body(c.textMuted)),
                      for (final snapshot in snapshots)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(
                            snapshot.manifest.createdAt
                                .toLocal()
                                .toString()
                                .split('.')
                                .first,
                            style: GtText.body(c.textPrimary)
                                .copyWith(fontSize: 13),
                          ),
                          subtitle: Text(
                            '${snapshot.manifest.bookCount} 本书 · ${formatBytes(snapshot.manifest.totalBytes)}',
                            style: GtText.caption(c.textSecondary),
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              GtButton(
                                onPressed: state.busy
                                    ? null
                                    : () => vm.save(snapshot),
                                child: const Text('导出'),
                              ),
                              GtButton(
                                style: TextButton.styleFrom(
                                  foregroundColor: c.danger,
                                ),
                                onPressed: state.busy
                                    ? null
                                    : () async {
                                        final accepted = await showDialog<bool>(
                                          context: context,
                                          builder: (context) => AlertDialog(
                                            backgroundColor: c.surface,
                                            surfaceTintColor:
                                                Colors.transparent,
                                            title: const Text('删除这份自动快照？'),
                                            content: const Text(
                                              '删除后无法再导出或用它恢复。当前书库和其它快照不受影响。',
                                            ),
                                            actions: [
                                              GtDialogAction(
                                                onPressed: () => Navigator.pop(
                                                  context,
                                                  false,
                                                ),
                                                label: '取消',
                                              ),
                                              GtDialogAction(
                                                role: GtDialogActionRole.danger,
                                                onPressed: () => Navigator.pop(
                                                  context,
                                                  true,
                                                ),
                                                label: '删除',
                                              ),
                                            ],
                                          ),
                                        );
                                        if (accepted == true &&
                                            context.mounted) {
                                          await vm.deleteSaved(snapshot);
                                        }
                                      },
                                child: const Text('删除'),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
