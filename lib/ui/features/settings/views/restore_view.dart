import 'package:taletin/ui/core/widgets/gt_app_bar.dart';
import 'package:taletin/ui/core/widgets/gt_button.dart';
import 'package:taletin/ui/core/widgets/gt_dialog_action.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../platform/channels/system_toast.dart';
import '../../../../domain/use_cases/delete_books.dart' show formatBytes;
import '../../../core/theme/gt_tokens.dart';
import '../view_models/restore_view_model.dart';
import '../widgets/settings_progress.dart';

class RestoreView extends ConsumerWidget {
  const RestoreView({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(restoreViewProvider);
    ref.listen(restoreViewProvider, (previous, next) {
      if (next.cancelled && previous?.cancelled != true) {
        SystemToast.show('操作已取消').ignore();
      }
    });
    final vm = ref.read(restoreViewProvider.notifier);
    final preview = state.preview, manifest = state.preview?.snapshot.manifest;
    return PopScope(
      canPop: !state.busy,
      child: Scaffold(
        appBar: GtAppBar(title: const Text('恢复备份')),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(GtSpacing.s5),
            children: [
              const Text('先选择备份并完整校验，再确认是否恢复。选择和校验期间不会修改当前书库。'),
              const SizedBox(height: GtSpacing.s5),
              if (manifest != null) ...[
                Text('${manifest.bookCount} 本书 · ${preview!.noteCount} 条高亮和笔记'),
                Text('数据体积 ${formatBytes(manifest.totalBytes)}'),
                Text('创建时间：${manifest.createdAt.toLocal()}'),
                const SizedBox(height: GtSpacing.s5),
                const Text(
                  '恢复会整体替换当前书籍、笔记、进度、统计、成就和设置。恢复前自动保存当前快照，可在备份页查看和导出。',
                ),
                GtButton.filled(
                  onPressed: state.busy
                      ? null
                      : () async {
                          final accepted = await showDialog<bool>(
                            context: context,
                            builder: (context) => AlertDialog(
                              title: const Text('确认整体恢复？'),
                              content: const Text(
                                '将替换当前全部书库数据。听书和自动阅读会停止；恢复前自动保存当前书库。替换期间请等待完成。',
                              ),
                              actions: [
                                GtDialogAction(
                                  onPressed: () =>
                                      Navigator.pop(context, false),
                                  label: '取消',
                                ),
                                GtDialogAction(
                                  role: GtDialogActionRole.danger,
                                  filled: true,
                                  onPressed: () => Navigator.pop(context, true),
                                  label: '确认恢复',
                                ),
                              ],
                            ),
                          );
                          if (accepted == true) await vm.restore();
                        },
                  child: const Text('恢复此备份'),
                ),
              ],
              if (state.busy)
                SettingsProgress(
                  label: state.message,
                  fraction: state.fraction,
                ),
              if (!state.busy && state.message.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: GtSpacing.s4),
                  child: Text(state.message),
                ),
              const SizedBox(height: GtSpacing.s3),
              GtButton.filled(
                onPressed: state.busy ? null : vm.inspect,
                child: const Text('选择备份并校验'),
              ),
              if (state.busy)
                GtButton(onPressed: vm.cancel, child: const Text('取消操作')),
            ],
          ),
        ),
      ),
    );
  }
}
