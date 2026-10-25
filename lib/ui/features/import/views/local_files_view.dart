import 'dart:async';

import 'package:flutter/material.dart';

import '../../../../core/diagnostics/app_errors.dart';
import '../../../../app/di/imported_font_providers.dart';
import '../../../../app/di/app_font_providers.dart';
import '../../../../platform/channels/imported_fonts.dart';
import '../../../../platform/channels/reading_fonts.dart';

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
  const LocalFilesView({
    super.key,
    this.selectionOnly = false,
    this.purpose = LocalFilePurpose.books,
  });
  final bool selectionOnly;
  final LocalFilePurpose purpose;
  @override
  ConsumerState<LocalFilesView> createState() => _LocalFilesViewState();
}

class _LocalFilesViewState extends ConsumerState<LocalFilesView>
    with WidgetsBindingObserver {
  bool _searching = false, _submitting = false;
  bool get _fonts => widget.purpose == LocalFilePurpose.fonts;
  NotifierProvider<LocalFilesViewModel, LocalFilesState> get _filesProvider =>
      _fonts ? localFontFilesProvider : localFilesProvider;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        ref.read(_filesProvider.notifier).load(LocalFilesMode.smart);
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_submitting) {
      unawaited(ref.read(_filesProvider.notifier).checkForChanges(force: true));
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(_filesProvider);
    final vm = ref.read(_filesProvider.notifier);
    if (!_fonts) {
      ref.listen(libraryBooksProvider, (_, next) {
        if (next.hasValue) vm.refreshImported();
      });
    }
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
                  onRescan: () =>
                      vm.load(state.mode, path: state.path, rescan: true),
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
                          onPressed: () => vm.load(
                            state.mode,
                            path: state.path,
                            rescan: true,
                          ),
                          child: const Text('重试'),
                        ),
                    ],
                  ),
                ),
              if (state.needsRescan || state.scanIncomplete)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: GtSpacing.s5),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          state.needsRescan
                              ? '手机中的文件有变化，请重新扫描'
                              : '部分文件暂时无法确认，可重新扫描',
                        ),
                      ),
                      GtButton(
                        onPressed: state.busy || _submitting
                            ? null
                            : () => vm.load(
                                state.mode,
                                path: state.path,
                                rescan: true,
                              ),
                        child: const Text('重新扫描'),
                      ),
                    ],
                  ),
                ),
              Expanded(
                child: FrameFade(
                  revision: state.sort,
                  child: AbsorbPointer(
                    absorbing: _submitting || state.busy,
                    // 首次扫描没有旧结果；重新扫描保留原列表和滚动位置。
                    child: state.busy && state.entries.isEmpty
                        ? const SizedBox.expand()
                        : !state.busy && state.visible.isEmpty
                        ? Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  state.message == null
                                      ? widget.purpose.emptyMessage
                                      : state.message!,
                                ),
                                GtButton(
                                  onPressed: () => vm.load(
                                    state.mode,
                                    path: state.path,
                                    rescan: true,
                                  ),
                                  child: const Text('重新读取'),
                                ),
                              ],
                            ),
                          )
                        : LocalFileList(
                            state: state,
                            importing: _fonts
                                ? const {}
                                : {
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
            onDelete: _fonts ? null : _delete,
            onImport: () => _import(),
            importLabel: _fonts ? '导入字体' : '加入书架',
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
        content: Text('将永久删除选中的 $count 个图书文件，无法撤销。使用这些原文件的书架图书将会失效。'),
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
    if (_fonts) {
      await _importFonts(single);
      return;
    }
    final state = ref.read(localFilesProvider);
    if (state.busy || _submitting) return;
    setState(() => _submitting = true);
    try {
      final vm = ref.read(localFilesProvider.notifier);
      final entries = await vm.validateForImport(
        (single == null ? state.selected.values : [single]).toList(),
      );
      if (!mounted) return;
      final checked = ref.read(localFilesProvider);
      final queued = {
        for (final item in ref.read(importProvider).items)
          if (!item.stage.isFinished) item.key,
      };
      // 点击书名只取该书，不能把已有多选一起带入队列。
      final documents = entries
          .where(
            (e) =>
                !checked.imported.contains(e.path) &&
                !queued.contains(e.document.uri),
          )
          .map((e) => e.document)
          .toList();
      if (documents.isEmpty) return;
      if (checked.message != null) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(checked.message!)));
      }
      if (widget.selectionOnly) {
        Navigator.pop<List<PickedDocument>>(context, documents);
        return;
      }
      ref.read(importProvider.notifier).enqueue(documents);
      context.go(AppRoutes.shelf);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _importFonts(LocalBookEntry? single) async {
    final state = ref.read(_filesProvider);
    if (state.busy || _submitting) return;
    final selected = (single == null ? state.selected.values : [single])
        .where((e) => !e.directory && !state.imported.contains(e.path))
        .toList();
    if (selected.isEmpty) return;
    setState(() => _submitting = true);
    var failed = 0;
    try {
      final entries = await ref
          .read(_filesProvider.notifier)
          .validateForImport(selected);
      if (!mounted || entries.isEmpty) return;
      failed = selected.length - entries.length;
      final store = ref.read(importedFontStoreProvider);
      for (final entry in entries) {
        try {
          await store.importFile(entry.path, prepare: ImportedFonts.prepare);
        } catch (error, stack) {
          failed++;
          AppErrors.report(error, stack, operation: '导入字体失败');
        }
      }
      // 这里只更新可选名单，不调用全局设置或单书设置的写入入口。
      await ReadingFonts.refreshImported();
      if (!mounted) return;
      ref.invalidate(fontFamilyNamesProvider);
      ref.invalidate(currentTypographyFontsProvider);
      await ref.read(fontFamilyNamesProvider.future);
      if (!mounted) return;
      if (failed == 0) {
        Navigator.pop(context, true);
      } else {
        final vm = ref.read(_filesProvider.notifier);
        await vm.refreshImported();
        if (mounted) vm.showMessage('$failed 个字体导入失败，成功项已保存');
      }
    } catch (error, stack) {
      AppErrors.report(error, stack, operation: '更新字体列表失败');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }
}
