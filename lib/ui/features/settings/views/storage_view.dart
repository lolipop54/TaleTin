import 'package:taletin/ui/core/widgets/gt_app_bar.dart';
import 'package:taletin/ui/core/widgets/gt_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../platform/channels/system_toast.dart';
import '../../../core/widgets/book_loading.dart';
import '../../../core/widgets/frame_fade.dart';

import '../view_models/storage_view_model.dart';

class StorageView extends ConsumerStatefulWidget {
  const StorageView({super.key});
  @override
  ConsumerState<StorageView> createState() => _StorageState();
}

class _StorageState extends ConsumerState<StorageView> {
  bool busy = false;
  Future<void> run(bool clear) async {
    setState(() {
      busy = true;
    });
    try {
      final vm = ref.read(storageUsageProvider.notifier);
      if (clear) {
        await vm.clear();
      } else {
        await vm.refresh();
      }
      if (mounted) {
        SystemToast.show(clear ? '缓存已清理，容量已更新' : '容量已更新').ignore();
      }
    } catch (_) {
      if (mounted) {
        SystemToast.show('操作未完成，请重试').ignore();
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(storageUsageProvider), data = state.value;
    // 重试时 Riverpod 会保留上一次异常，但新的统计已经在进行，显示计算占位。
    final failed = state.hasError && !state.isLoading;
    return Scaffold(
      appBar: GtAppBar(title: const Text('存储与缓存')),
      body: SafeArea(
        // 页面立即打开，计算期间保持完整页面尺寸，结果就绪后再淡化交接。
        child: SizedBox.expand(
          child: AnimatedSwitcher(
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : pageFadeDuration,
            child: data == null
                ? Center(
                    key: ValueKey(failed ? 'storage-error' : 'storage-loading'),
                    child: failed
                        ? GtButton(
                            onPressed: () =>
                                ref.invalidate(storageUsageProvider),
                            child: const Text('容量读取失败，重试'),
                          )
                        : const BookLoading(label: '计算中...'),
                  )
                : ListView(
                    key: const ValueKey('storage-content'),
                    padding: const EdgeInsets.all(20),
                    children: [
                      Text(
                        '阅读数据 ${storageSize(data.totalBytes)}',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const Text('按应用私有目录内实际文件大小统计。'),
                      const SizedBox(height: 16),
                      for (final entry in data.categories.entries)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(entry.key),
                          trailing: Text(storageSize(entry.value)),
                        ),
                      const Divider(),
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('当前可清理'),
                        trailing: Text(storageSize(data.clearableBytes)),
                      ),
                      const SizedBox(height: 16),
                      GtButton.filled(
                        onPressed: busy || data.clearableBytes == 0
                            ? null
                            : () => run(true),
                        child: Text(busy ? '正在处理…' : '清理缓存'),
                      ),
                      GtButton(
                        onPressed: busy ? null : () => run(false),
                        child: const Text('重新统计'),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}
