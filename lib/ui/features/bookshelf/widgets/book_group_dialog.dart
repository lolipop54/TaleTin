import 'package:taletin/core/diagnostics/app_errors.dart';
import 'package:flutter/material.dart';
import 'package:forui/forui.dart';

import '../../../../domain/models/book_group.dart';
import '../../../../domain/repositories/book_group_repository.dart';
import '../../../core/widgets/gt_dialog_action.dart';

Future<BookGroup?> showBookGroupDialog(
  BuildContext context,
  BookGroupRepository repository, {
  BookGroup? group,
}) => showDialog<BookGroup>(
  context: context,
  barrierDismissible: false,
  builder: (_) => _BookGroupDialog(repository: repository, group: group),
);

Future<bool> confirmBookGroupDeletion(
  BuildContext context,
  BookGroup group,
) async =>
    await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        scrollable: true,
        title: Text('删除分组“${group.name}”？'),
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
    ) ??
    false;

class _BookGroupDialog extends StatefulWidget {
  const _BookGroupDialog({required this.repository, this.group});
  final BookGroupRepository repository;
  final BookGroup? group;
  @override
  State<_BookGroupDialog> createState() => _BookGroupDialogState();
}

class _BookGroupDialogState extends State<_BookGroupDialog> {
  late final controller = TextEditingController(text: widget.group?.name);
  bool saving = false;
  String? error;
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    if (saving) return;
    setState(() {
      saving = true;
      error = null;
    });
    try {
      final group = widget.group;
      final saved = group == null
          ? await widget.repository.create(controller.text)
          : await widget.repository.rename(group.id, controller.text);
      if (mounted) Navigator.pop(context, saved);
    } on FormatException catch (e) {
      showError(e.message);
    } catch (appError, appStack) {
      AppErrors.report(appError, appStack, operation: '保存分组失败');
      showError('分组没有保存成功，请重试');
    }
  }

  void showError(String message) {
    if (!mounted) return;
    setState(() {
      saving = false;
      error = message;
    });
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !saving,
    child: AlertDialog(
      title: Text(widget.group == null ? '新建分组' : '编辑分组'),
      content: SingleChildScrollView(
        child: FTextField(
          key: const ValueKey('book-group-name'),
          control: FTextFieldControl.managed(controller: controller),
          label: const Text('分组名称'),
          hint: '请输入分组名称',
          error: error == null ? null : Text(error!),
          autofocus: true,
          enabled: !saving,
          maxLength: 40,
          textInputAction: TextInputAction.done,
          onSubmit: (_) => submit(),
        ),
      ),
      actions: [
        GtDialogAction(
          key: const ValueKey('book-group-dialog-cancel'),
          onPressed: saving ? null : () => Navigator.pop(context),
          label: '取消',
        ),
        GtDialogAction(
          key: const ValueKey('book-group-dialog-confirm'),
          role: GtDialogActionRole.primary,
          onPressed: saving ? null : submit,
          label: widget.group == null ? '确认' : '确定',
        ),
      ],
    ),
  );
}
