import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/di/app_providers.dart';
import '../../../../domain/models/book.dart';
import '../../../../domain/models/import_job.dart';
import '../../../../platform/channels/system_toast.dart';
import '../../../core/theme/gt_tokens.dart';
import '../../../core/widgets/book_cover.dart';
import '../../../core/widgets/gt_button.dart';
import '../../../core/widgets/gt_dialog_action.dart';
import '../../bookshelf/widgets/bookshelf_widgets.dart';
import '../view_models/import_view_model.dart';

/// 数据库流收到正式书籍后才撤掉占位，避免入库交接时短暂消失。
final shelfImportItemsProvider =
    NotifierProvider<ShelfImportItems, Map<String, ImportItem>>(
      ShelfImportItems.new,
    );

class ShelfImportItems extends Notifier<Map<String, ImportItem>> {
  final _handedOff = <String>{};
  final _batchSlots = <String>{};

  @override
  Map<String, ImportItem> build() {
    final ids =
        ref.watch(libraryBooksProvider).value?.map((b) => b.id).toSet() ??
        <String>{};
    final queue = ref.watch(importProvider);
    final items = queue.items;
    if (!queue.running) _batchSlots.clear();
    // 正式书籍接管后不再恢复占位，避免以后删除书籍时旧任务重新出现。
    for (final item in items) {
      if (!item.stage.isFinished) {
        _handedOff.remove(item.key);
        if (queue.running) _batchSlots.add(item.key);
      } else if (item.stage != ImportStage.failed &&
          ids.contains(item.bookId)) {
        _handedOff.add(item.key);
      }
    }
    return {
      for (final item in items)
        if ((!_handedOff.contains(item.key) ||
                _batchSlots.contains(item.key)) &&
            item.stage != ImportStage.cancelled &&
            item.stage != ImportStage.duplicate &&
            (_batchSlots.contains(item.key) ||
                !item.stage.isFinished ||
                item.stage == ImportStage.failed ||
                !ids.contains(item.bookId)))
          'import:${item.key}': item,
    };
  }
}

/// 仅供书架排版的临时实体，不写入数据库，也不允许进入阅读器。
Book importPlaceholder(String id, ImportItem item) => Book(
  id: id,
  sourceHash: '',
  title: item.document.name.replaceFirst(RegExp(r'\.[^.]+$'), ''),
  author: '',
  format: item.document.name.toLowerCase().endsWith('.epub')
      ? BookFormat.epub
      : BookFormat.txt,
  importedAt: DateTime(1970),
);

class ShelfImportTile extends ConsumerWidget {
  const ShelfImportTile({
    super.key,
    required this.book,
    required this.item,
    this.listMode = false,
  });
  final Book book;
  final ImportItem item;
  final bool listMode;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 阶段权重只表示处理完成度，不估计剩余时间；入库完成前最多99%。
    final fraction = switch (item.stage) {
      ImportStage.waiting => 0.0,
      ImportStage.copying => (item.copyFraction ?? 0) * .2,
      ImportStage.parsing => .2 + (item.parseFraction ?? 0) * .75,
      ImportStage.committing => .99,
      ImportStage.done || ImportStage.duplicate => 1.0,
      _ => 0.0,
    };
    final overlay = DecoratedBox(
      decoration: BoxDecoration(
        color: context.gtColors.scrim.withValues(alpha: .55),
        borderRadius: BorderRadius.circular(GtRadius.cover),
      ),
      child: Center(
        child: item.stage == ImportStage.failed
            ? const Text('导入失败', style: TextStyle(color: Colors.white))
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox.square(
                    dimension: listMode ? 40 : 52,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        Positioned.fill(
                          child: CircularProgressIndicator(
                            value: fraction,
                            strokeWidth: 3,
                            color: Colors.white,
                            backgroundColor: Colors.white24,
                          ),
                        ),
                        Text(
                          '${(fraction * 100).floor()}%',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (item.stage == ImportStage.waiting)
                    const Text(
                      '等待导入',
                      style: TextStyle(color: Colors.white, fontSize: 10),
                    ),
                ],
              ),
      ),
    );
    void tap() {
      if (item.stage != ImportStage.failed) {
        SystemToast.show('正在导入中...');
        return;
      }
      showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(book.title),
          content: Text(item.failure?.displayText ?? '导入失败，请重试'),
          actions: [
            GtDialogAction(
              onPressed: () {
                ref.read(importProvider.notifier).dismissFinished(item.key);
                Navigator.pop(dialogContext);
              },
              label: '移除',
            ),
            GtDialogAction(
              role: GtDialogActionRole.primary,
              onPressed: () {
                ref.read(importProvider.notifier).retry(item.key);
                Navigator.pop(dialogContext);
              },
              label: '重试',
            ),
          ],
        ),
      );
    }

    if (!listMode) {
      return BookTile(
        book: book,
        coverOverlay: overlay,
        onTapOverride: tap,
        coverBytes: item.coverBytes,
      );
    }
    return GtButton.raw(
      onPressed: tap,
      child: Row(
        children: [
          SizedBox(
            width: 56,
            child: Stack(
              children: [
                BookCover(
                  bookId: book.id,
                  title: book.title,
                  author: '',
                  imageBytes: item.coverBytes,
                ),
                Positioned.fill(child: overlay),
              ],
            ),
          ),
          const SizedBox(width: GtSpacing.s3),
          Expanded(child: Text(book.title)),
        ],
      ),
    );
  }
}
