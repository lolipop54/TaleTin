import 'package:flutter/material.dart';
import 'package:forui/forui.dart';

import '../../../../domain/models/book_group.dart';
import '../../../../domain/repositories/book_group_repository.dart';
import '../../../core/widgets/gt_dialog_action.dart';

Future<BookGroup?> showNewBookGroupDialog(
  BuildContext context,
  BookGroupRepository repository,
) => showDialog<BookGroup>(
  context: context,
  barrierDismissible: false,
  builder: (_) => _NewBookGroupDialog(repository: repository),
);

class _NewBookGroupDialog extends StatefulWidget {
  const _NewBookGroupDialog({required this.repository});
  final BookGroupRepository repository;
  @override
  State<_NewBookGroupDialog> createState() => _NewBookGroupDialogState();
}

class _NewBookGroupDialogState extends State<_NewBookGroupDialog> {
  final controller = TextEditingController();
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
      final group = await widget.repository.create(controller.text);
      if (mounted) Navigator.pop(context, group);
    } on FormatException catch (e) {
      if (mounted) {
        setState(() {
          saving = false;
          error = e.message;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          saving = false;
          error = '分组没有保存成功，请重试';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !saving,
    child: AlertDialog(
      title: const Text('新建分组'),
      content: SingleChildScrollView(
        child: FTextField(
          key: const ValueKey('new-book-group-name'),
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
          key: const ValueKey('new-book-group-cancel'),
          onPressed: saving ? null : () => Navigator.pop(context),
          label: '取消',
        ),
        GtDialogAction(
          key: const ValueKey('new-book-group-confirm'),
          role: GtDialogActionRole.primary,
          onPressed: saving ? null : submit,
          label: saving ? '保存中…' : '确认',
        ),
      ],
    ),
  );
}
