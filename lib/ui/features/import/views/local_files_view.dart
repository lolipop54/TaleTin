import 'package:flutter/material.dart';

import '../../../core/widgets/frame_fade.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:go_router/go_router.dart';

import '../../../../app/router/app_router.dart';
import '../../../../app/di/app_providers.dart';
import '../../../../domain/services/document_platform.dart';
import '../../../../domain/services/local_book_files.dart';
import '../../../core/theme/gt_tokens.dart';
import '../../../core/widgets/gt_button.dart';
import '../../../core/widgets/gt_dialog_action.dart';
import '../view_models/import_view_model.dart';
import '../view_models/local_files_view_model.dart';
import '../widgets/local_file_bar.dart';
import '../widgets/local_file_header.dart';
import '../widgets/local_file_list.dart';

class LocalFilesView extends ConsumerStatefulWidget {
  const LocalFilesView({super.key, this.selectionOnly = false});
  final bool selectionOnly;
  @override
  ConsumerState<LocalFilesView> createState() => _LocalFilesViewState();
}

class _LocalFilesViewState extends ConsumerState<LocalFilesView> {
  bool _searching = false, _submitting = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        ref.read(localFilesProvider.notifier).load(LocalFilesMode.smart);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(localFilesProvider);
    final vm = ref.read(localFilesProvider.notifier);
    ref.listen(libraryBooksProvider, (_, next) {
      if (next.hasValue) vm.refreshImported();
    });
    return PopScope(
      canPop:
          !_submitting &&
          (state.path == null || state.mode == LocalFilesMode.smart),
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !_submitting) {
          vm.cancel();
          vm.up();
        }
      },
      child: Scaffold(
        backgroundColor: context.gtColors.canvas,
        body: SafeArea(
          bottom: false,
          child: Column(
            children: [
              AbsorbPointer(
                absorbing: _submitting,
                child: LocalFileHeader(
                  state: state,
                  searching: _searching,
                  onBack: () {
                    if (!_submitting) Navigator.of(context).maybePop();
                  },
                  onMode: (mode) {
                    setState(() => _searching = false);
                    vm.filter(query: '');
                    vm.load(mode);
                  },
                  onSearch: () {
                    setState(() => _searching = !_searching);
                    vm.filter(query: '');
                  },
                  onQuery: (query) => vm.filter(query: query),
                  onSort: vm.sortBy,
                  onUp: vm.up,
                ),
              ),
              if ((state.busy && state.scanning) ||
                  state.message != null ||
                  _submitting)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: GtSpacing.s5),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          _submitting
                              ? '正在处理所选文件…'
                              : state.busy
                              ? '正在读取，已检查 ${state.visited} 个目录…'
                              : state.message!,
                        ),
                      ),
                      if (state.busy && !_submitting)
                        GtButton(onPressed: vm.cancel, child: const Text('取消')),
                      if (!state.busy && !_submitting)
                        GtButton(
                          onPressed: () =>
                              vm.load(state.mode, path: state.path),
                          child: const Text('重试'),
                        ),
                    ],
                  ),
                ),
              Expanded(
                child: FrameFade(
                  revision: state.sort,
                  child: AbsorbPointer(
                    absorbing: _submitting || state.busy,
                    // 智能扫描期间只保留进度提示，旧结果不展示为不可点击的列表。
                    child: state.busy && state.scanning
                        ? const SizedBox.expand()
                        : !state.busy && state.visible.isEmpty
                        ? Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  state.message == null
                                      ? '没有找到 TXT、EPUB 文件'
                                      : state.message!,
                                ),
                                GtButton(
                                  onPressed: () =>
                                      vm.load(state.mode, path: state.path),
                                  child: const Text('重新读取'),
                                ),
                              ],
                            ),
                          )
                        : LocalFileList(
                            state: state,
                            importing: {
                              for (final item
                                  in ref.watch(importProvider).items)
                                if (!item.stage.isFinished) item.key,
                            },
                            onImport: (entry) => _import(single: entry),
                            onTap: (entry) => entry.directory
                                ? vm.load(
                                    LocalFilesMode.folders,
                                    path: entry.path,
                                  )
                                : vm.toggle(entry),
                          ),
                  ),
                ),
              ),
            ],
          ),
        ),
        bottomNavigationBar: AbsorbPointer(
          absorbing: state.busy,
          child: LocalFileBar(
            count: state.selected.length,
            allSelected: vm.allSelected,
            busy: (state.busy && state.scanning) || _submitting,
            onAll: vm.toggleAll,
            onDelete: _delete,
            onImport: () => _import(),
          ),
        ),
      ),
    );
  }

  Future<void> _delete() async {
    final count = ref.read(localFilesProvider).selected.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除手机源文件？'),
        content: Text('将永久删除选中的 $count 个 TXT/EPUB 文件，无法撤销。已加入书架的副本不受影响。'),
        actions: [
          GtDialogAction(
            onPressed: () => Navigator.pop(context, false),
            label: '取消',
          ),
          GtDialogAction(
            role: GtDialogActionRole.danger,
            onPressed: () => Navigator.pop(context, true),
            label: '删除',
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _submitting = true);
    try {
      await ref.read(localFilesProvider.notifier).deleteSelected();
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _import({LocalBookEntry? single}) async {
    final state = ref.read(localFilesProvider);
    if (state.busy) return;
    final queued = {
      for (final item in ref.read(importProvider).items)
        if (!item.stage.isFinished) item.key,
    };
    // 点击书名只取该书，不能把已有多选一起带入队列。
    final documents = (single == null ? state.selected.values : [single])
        .where(
          (e) =>
              !state.imported.contains(e.path) &&
              !queued.contains(e.document.uri),
        )
        .map((e) => e.document)
        .toList();
    if (documents.isEmpty) return;
    if (widget.selectionOnly) {
      Navigator.pop<List<PickedDocument>>(context, documents);
      return;
    }
    ref.read(importProvider.notifier).enqueue(documents);
    context.go(AppRoutes.shelf);
  }
}
