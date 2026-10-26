import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/di/app_providers.dart';
import '../../../../core/diagnostics/app_errors.dart';
import '../../../../domain/models/book.dart';
import '../../../../domain/use_cases/delete_books.dart';
import '../../../../platform/channels/system_toast.dart';
import '../../../core/theme/gt_tokens.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/gt_button.dart';
import '../../../core/widgets/gt_dialog_action.dart';
import '../../../core/widgets/gt_icon.dart';
import '../view_models/bookshelf_view_model.dart';
import '../view_models/visible_shelf_books.dart';
import 'book_group_sheet.dart';
import 'book_cover_sheet.dart';

/// 位于主导航之上，四格始终等宽；取消最后一本仍留在这里。
class ShelfSelectionBar extends ConsumerWidget {
  const ShelfSelectionBar({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.gtColors;
    final shelf = ref.watch(bookshelfProvider);
    final books = ref.watch(libraryBooksProvider).value ?? <Book>[];
    final visible =
        ref.watch(visibleShelfBooksProvider).value ?? const <Book>[];
    final selected = books
        .where((b) => shelf.selectedIds.contains(b.id))
        .toList();
    final all =
        visible.isNotEmpty &&
        shelf.selectedIds.containsAll(visible.map((b) => b.id));
    Widget action(
      String key,
      String label,
      String icon,
      VoidCallback? press, {
      bool danger = false,
    }) {
      final color = press == null
          ? colors.textMuted
          : danger
          ? colors.danger
          : colors.textPrimary;
      return Expanded(
        child: GtButton.raw(
          key: ValueKey(key),
          tooltip: label,
          borderRadius: BorderRadius.zero,
          onPressed: press,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 2),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                GtIcon(icon, size: 24, color: color),
                const SizedBox(height: 7),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    label,
                    style: TextStyle(fontSize: 13, height: 1.4, color: color),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    // 手势导航的手机常常不报底部 viewPadding（Home 手势区不占布局），
    // 只按 viewPadding 会让四个按钮贴着屏幕底边。手势区有值时用它，
    // 两者都为 0 时也至少留出 24dp，和系统底部导航区的高度相当。
    final bottomInset = math.max(
      math.max(
        MediaQuery.viewPaddingOf(context).bottom,
        MediaQuery.systemGestureInsetsOf(context).bottom,
      ),
      GtSpacing.s6,
    );
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 1, end: 0),
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 200),
      curve: Curves.easeOutCubic,
      builder: (_, value, child) =>
          FractionalTranslation(translation: Offset(0, value), child: child),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.surface,
          border: Border(top: BorderSide(color: colors.borderSubtle)),
        ),
        child: Padding(
          padding: EdgeInsets.only(bottom: bottomInset),
          child: Row(
            children: [
              action(
                'shelf-select-all',
                all ? '取消全选' : '全选',
                all ? GtIcons.checkbox : GtIcons.checkboxSelected,
                () => ref
                    .read(bookshelfProvider.notifier)
                    .toggleSelectAll(visible.map((b) => b.id)),
              ),
              action(
                'shelf-move-selected',
                '分组',
                GtIcons.folderInput,
                selected.isEmpty
                    ? null
                    : () => showBookGroupSheet(context, ref, selected),
              ),
              action(
                'shelf-cover-selected',
                '自定义封面',
                GtIcons.palette,
                selected.length != 1
                    ? null
                    : () => showBookCoverSheet(context, ref, selected),
              ),
              action(
                'shelf-delete-selected',
                '删除',
                GtIcons.trash,
                selected.isEmpty
                    ? null
                    : () => _confirmDelete(context, ref, books),
                danger: true,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 删除所选书籍：先说明影响（占用空间、保留书籍记录），确认后再删。
  Future<void> _confirmDelete(
    BuildContext context,
    WidgetRef ref,
    List<Book> visible,
  ) async {
    final shelf = ref.read(bookshelfProvider);
    final selected = [
      for (final book in visible)
        if (shelf.selectedIds.contains(book.id)) book,
    ];
    if (selected.isEmpty) return;

    final deleteBooks = ref.read(deleteBooksProvider);
    final size = await deleteBooks.estimateSize(selected.map((b) => b.id));
    if (!context.mounted) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('删除 ${selected.length} 本书籍？'),
        content: Text(
          '会清理正文、封面、阅读进度、笔记、单书设置和统计，不能恢复；不删除手机目录中的原文件，'
          '共约 ${formatBytes(size)}，删除后书架不再显示。',
          style: GtText.body(context.gtColors.textSecondary)
              .copyWith(fontSize: 14, height: 1.6),
        ),
        actions: [
          GtDialogAction(
            key: const ValueKey('shelf-delete-cancel'),
            onPressed: () => Navigator.of(dialogContext).pop(false),
            label: '取消',
          ),
          GtDialogAction(
            key: const ValueKey('shelf-delete-confirm'),
            role: GtDialogActionRole.danger,
            onPressed: () => Navigator.of(dialogContext).pop(true),
            label: '删除',
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      final result = await deleteBooks.run(
        selected.map((b) => b.id),
        now: DateTime.now().toUtc(),
      );
      if (!context.mounted) return;
      // 这些书已经从数据库流里消失，选择集合里也要去掉，避免残留选中态
      ref.read(bookshelfProvider.notifier).pruneSelection(result.undeletedIds);
      SystemToast.show(
        result.undeletedIds.isNotEmpty
            ? '已删除 ${result.deletedCount} 本，${result.undeletedIds.length} 本未删除，请重试'
            : result.failedCount == 0
            ? '已删除 ${result.deletedCount} 本，释放 ${formatBytes(result.freedBytes)}'
            : '已删除 ${result.deletedCount} 本，其中 ${result.failedCount} 本的文件将在下次启动时清理',
      ).ignore();
    } catch (error, appStack) {
      AppErrors.report(error, appStack, operation: '删除书籍失败', notify: false);
      if (!context.mounted) return;
      AppErrors.report(error, appStack, operation: '删除书籍失败');
    }
  }
}
