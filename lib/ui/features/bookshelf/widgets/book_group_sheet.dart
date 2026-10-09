import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/di/book_group_providers.dart';
import '../../../../domain/models/book.dart';
import '../../../../domain/models/book_group.dart';
import '../../../../domain/repositories/book_group_repository.dart';
import '../../../core/theme/gt_tokens.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/gt_button.dart';
import '../../../core/widgets/gt_dialog_action.dart';
import '../view_models/bookshelf_view_model.dart';
import 'book_group_row.dart';
import 'new_book_group_dialog.dart';

Future<void> showBookGroupSheet(
  BuildContext context,
  WidgetRef ref,
  List<Book> books,
) async {
  final groups = await ref.read(bookGroupsProvider.future);
  if (!context.mounted) return;
  final moved = await showModalBottomSheet<bool>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: false,
    shape: const RoundedRectangleBorder(),
    backgroundColor: context.gtColors.surface,
    sheetAnimationStyle: MediaQuery.disableAnimationsOf(context)
        ? AnimationStyle.noAnimation
        : null,
    builder: (_) => BookGroupSheet(
      groups: groups,
      books: books,
      repository: ref.read(bookGroupRepositoryProvider),
      onDeleted: (id) {
        if (ref.read(bookshelfProvider).groupId == id) {
          ref.read(bookshelfProvider.notifier).setFilter(ShelfFilter.ungrouped);
        }
      },
    ),
  );
  if (moved == true && context.mounted) {
    ref.read(bookshelfProvider.notifier).clearSelection();
  }
}

/// 打开时使用完整快照；保存顺序失败才恢复原顺序，不刷新成空列表。
class BookGroupSheet extends StatefulWidget {
  const BookGroupSheet({
    super.key,
    required this.groups,
    required this.books,
    required this.repository,
    this.onDeleted,
  });
  final List<BookGroup> groups;
  final List<Book> books;
  final BookGroupRepository repository;
  final ValueChanged<String>? onDeleted;
  @override
  State<BookGroupSheet> createState() => _BookGroupSheetState();
}

class _BookGroupSheetState extends State<BookGroupSheet> {
  late List<BookGroup> groups = [...widget.groups];
  late final memberships = widget.books.map((b) => b.groupId).toSet();
  bool busy = false;
  String? error;

  Future<void> move(String? id) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.repository.moveBooks(
        widget.books.map((b) => b.id).toSet(),
        id,
      );
      if (mounted) Navigator.pop(context, true);
    } catch (_) {
      if (mounted) {
        setState(() {
          busy = false;
          error = '移动没有完成，请重试';
        });
      }
    }
  }

  Future<void> reorder(int oldIndex, int newIndex) async {
    if (busy) return;
    if (oldIndex == newIndex) return;
    final previous = [...groups];
    setState(() {
      groups.insert(newIndex, groups.removeAt(oldIndex));
      busy = true;
      error = null;
    });
    try {
      await widget.repository.reorder(groups.map((g) => g.id).toList());
      if (mounted) setState(() => busy = false);
    } catch (_) {
      if (mounted) {
        setState(() {
          groups = previous;
          busy = false;
          error = '顺序没有保存成功，请重试';
        });
      }
    }
  }

  Future<void> delete(String id) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    final name = groups.firstWhere((group) => group.id == id).name;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        scrollable: true,
        title: Text('删除分组“$name”？'),
        content: const Text('组内书籍将移到“未分组”，书籍、笔记和阅读记录会保留。'),
        actions: [
          GtDialogAction(
            key: const ValueKey('book-group-delete-cancel'),
            onPressed: () => Navigator.pop(dialogContext, false),
            label: '取消',
          ),
          GtDialogAction(
            key: const ValueKey('book-group-delete-confirm'),
            role: GtDialogActionRole.danger,
            onPressed: () => Navigator.pop(dialogContext, true),
            label: '删除',
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (confirmed != true) {
      setState(() => busy = false);
      return;
    }
    try {
      await widget.repository.delete(id);
      if (!mounted) return;
      setState(() {
        groups = groups.where((g) => g.id != id).toList();
        if (memberships.remove(id)) memberships.add(null);
        busy = false;
      });
      widget.onDeleted?.call(id);
    } catch (_) {
      if (mounted) {
        setState(() {
          busy = false;
          error = '分组没有删除成功，请重试';
        });
      }
    }
  }

  Future<void> create() async {
    if (busy) return;
    final group = await showNewBookGroupDialog(context, widget.repository);
    if (group != null && mounted) setState(() => groups = [...groups, group]);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.gtColors;
    return PopScope(
      canPop: !busy,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * .72,
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 24, 20, 16),
                child: Text(
                  '移动到分组',
                  style: GtText.sectionTitle(colors.textPrimary),
                ),
              ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Text(error!, style: GtText.body(colors.danger)),
                ),
              Flexible(
                child: ReorderableListView(
                  key: const ValueKey('book-group-list'),
                  shrinkWrap: true,
                  buildDefaultDragHandles: false,
                  padding: EdgeInsets.zero,
                  onReorderItem: reorder,
                  header: BookGroupRow(
                    key: const ValueKey('book-group-ungrouped'),
                    name: '未分组',
                    selected:
                        memberships.length == 1 && memberships.single == null,
                    onTap: busy ? null : () => move(null),
                  ),
                  footer: Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: GtButton(
                        key: const ValueKey('book-group-create'),
                        onPressed: busy ? null : create,
                        child: const Text('新建分组'),
                      ),
                    ),
                  ),
                  children: [
                    for (var i = 0; i < groups.length; i++)
                      BookGroupRow(
                        key: ValueKey('book-group-${groups[i].id}'),
                        name: groups[i].name,
                        selected:
                            memberships.length == 1 &&
                            memberships.single == groups[i].id,
                        onTap: busy ? null : () => move(groups[i].id),
                        dragIndex: i,
                        onDelete: busy ? null : () => delete(groups[i].id),
                        onMoveUp: busy || i == 0
                            ? null
                            : () => reorder(i, i - 1),
                        onMoveDown: busy || i == groups.length - 1
                            ? null
                            : () => reorder(i, i + 1),
                      ),
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
