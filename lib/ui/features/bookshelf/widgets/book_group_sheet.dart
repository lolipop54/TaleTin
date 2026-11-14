import 'package:taletin/core/diagnostics/app_errors.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/di/book_group_providers.dart';
import '../../../../domain/models/book.dart';
import '../../../../domain/models/book_group.dart';
import '../../../../domain/repositories/book_group_repository.dart';
import '../../../../platform/channels/system_toast.dart';
import '../../../core/theme/gt_tokens.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/gt_button.dart';
import '../view_models/bookshelf_view_model.dart';
import 'book_group_dialog.dart';
import 'book_group_row.dart';

Future<void> showBookGroupSheet(
  BuildContext context,
  WidgetRef ref, {
  List<Book> books = const [],
}) async {
  final groups = await ref.read(bookGroupsProvider.future);
  if (!context.mounted) return;
  await showModalBottomSheet<bool>(
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
      onDeleted: ref.read(bookshelfProvider.notifier).groupDeleted,
    ),
  );
}

/// 打开时使用完整快照；保存顺序失败才恢复原顺序，不刷新成空列表。
class BookGroupSheet extends StatefulWidget {
  const BookGroupSheet({
    super.key,
    required this.groups,
    this.books = const [],
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
  bool sorting = false;
  bool busy = false;
  bool finishAfterSave = false;
  String? error;

  // 书架分组栏打开面板时没有待移动的书，分组行只显示名称和管理按钮。
  bool get canMoveBooks => widget.books.isNotEmpty;

  void toggleSorting() {
    // 允许保存期间点「完成」，等写入成功再恢复移动和编辑，避免两次修改交叉。
    if (busy) {
      finishAfterSave = true;
      return;
    }
    setState(() => sorting = !sorting);
  }

  Future<void> move(String? id) async {
    if (!canMoveBooks || busy || sorting) return;
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
    } catch (appError, appStack) {
      AppErrors.report(appError, appStack, operation: '移动书籍失败');
      if (mounted) {
        setState(() {
          busy = false;
          error = '移动没有完成，请重试';
        });
      }
    }
  }

  Future<void> reorder(int oldIndex, int newIndex) async {
    if (busy || !sorting || oldIndex == newIndex) return;
    final previous = [...groups];
    setState(() {
      groups.insert(newIndex, groups.removeAt(oldIndex));
      busy = true;
      error = null;
    });
    try {
      await widget.repository.reorder(groups.map((g) => g.id).toList());
      if (mounted) {
        setState(() {
          busy = false;
          if (finishAfterSave) sorting = false;
          finishAfterSave = false;
        });
      }
    } catch (appError, appStack) {
      AppErrors.report(appError, appStack, operation: '分组排序未保存');
      if (mounted) {
        setState(() {
          groups = previous;
          busy = false;
          finishAfterSave = false;
          error = '顺序没有保存成功，请重试';
        });
      }
    }
  }

  Future<void> delete(BookGroup group) async {
    if (busy || sorting) return;
    setState(() {
      busy = true;
      error = null;
    });
    final confirmed = await confirmBookGroupDeletion(context, group);
    if (!mounted) return;
    if (!confirmed) {
      setState(() => busy = false);
      return;
    }
    final id = group.id;
    try {
      await widget.repository.delete(id);
      if (!mounted) return;
      setState(() {
        groups = groups.where((g) => g.id != id).toList();
        if (memberships.remove(id)) memberships.add(null);
        busy = false;
      });
      widget.onDeleted?.call(id);
    } catch (appError, appStack) {
      AppErrors.report(appError, appStack, operation: '删除分组失败');
      if (mounted) {
        setState(() {
          busy = false;
          error = '分组没有删除成功，请重试';
        });
      }
    }
  }

  Future<void> edit(BookGroup group) async {
    if (busy || sorting) return;
    final edited = await showBookGroupDialog(
      context,
      widget.repository,
      group: group,
    );
    if (edited == null || !mounted) return;
    setState(() {
      groups = [for (final row in groups) row.id == edited.id ? edited : row];
      error = null;
    });
  }

  Future<void> create() async {
    if (busy || sorting) return;
    final group = await showBookGroupDialog(context, widget.repository);
    if (group == null || !mounted) return;
    setState(() {
      groups = [...groups, group];
      error = null;
    });
    if (canMoveBooks) {
      SystemToast.show('退出多选后，长按书架分组标签可编辑分组').ignore();
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.gtColors;
    final canSelectGroup = canMoveBooks && !busy && !sorting;
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
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        canMoveBooks ? '移动到分组' : '编辑分组',
                        style: GtText.sectionTitle(colors.textPrimary),
                      ),
                    ),
                    GtButton(
                      key: const ValueKey('book-group-sort'),
                      onPressed: groups.isEmpty || (busy && !sorting)
                          ? null
                          : toggleSorting,
                      child: Text(sorting ? '完成' : '排序'),
                    ),
                  ],
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
                    onTap: canSelectGroup ? () => move(null) : null,
                  ),
                  footer: Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: GtButton(
                        key: const ValueKey('book-group-create'),
                        onPressed: busy || sorting ? null : create,
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
                        onTap: canSelectGroup ? () => move(groups[i].id) : null,
                        showActions: !sorting,
                        onEdit: busy ? null : () => edit(groups[i]),
                        onDelete: busy ? null : () => delete(groups[i]),
                        dragIndex: sorting ? i : null,
                        dragEnabled: !busy,
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
