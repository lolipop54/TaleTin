import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../app/di/app_providers.dart';
import '../../../../app/router/app_router.dart';
import '../../../../domain/models/book.dart';
import '../../../core/theme/gt_tokens.dart';
import '../../../core/widgets/gt_dialog_action.dart';
import '../view_models/bookshelf_view_model.dart';

/// 点击前再查一次，覆盖外部删除尚未被书架轮询发现的间隙。
Future<void> openShelfBook(
  BuildContext context,
  WidgetRef ref,
  Book book,
) async {
  final repository = ref.read(bookRepositoryProvider);
  final current = await repository.findById(book.id);
  if (!context.mounted ||
      current == null ||
      current.status == BookStatus.removed) {
    return;
  }
  if (current.status == BookStatus.active) {
    context.push(AppRoutes.reader(book.id));
    return;
  }
  var cleanOthers = false;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, update) {
        final colors = context.gtColors;
        return AlertDialog(
          backgroundColor: colors.surface,
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(2)),
          ),
          title: Text(
            '无效图书，请删除',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: colors.textPrimary,
            ),
          ),
          content: CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            dense: true,
            value: cleanOthers,
            onChanged: (value) => update(() => cleanOthers = value!),
            title: Text(
              '清理掉其它无效图书',
              style: TextStyle(fontSize: 14, color: colors.textMuted),
            ),
          ),
          actions: [
            GtDialogAction(
              onPressed: () => Navigator.pop(dialogContext, false),
              label: '取消',
            ),
            // 文案虽然是“确定”，实际会删除失效书籍，因此使用危险操作色。
            GtDialogAction(
              onPressed: () => Navigator.pop(dialogContext, true),
              role: GtDialogActionRole.danger,
              label: '确定',
            ),
          ],
        );
      },
    ),
  );
  if (confirmed != true || !context.mounted) return;
  // 确认前源文件可能已恢复，只清理现在仍失效的条目。
  final latest = await repository.watchActiveBooks().first;
  final ids = latest
      .where(
        (b) =>
            b.status == BookStatus.contentMissing &&
            (b.id == book.id || cleanOthers),
      )
      .map((b) => b.id)
      .toList();
  if (!context.mounted) return;
  await ref.read(deleteBooksProvider).run(ids, now: DateTime.now().toUtc());
  if (context.mounted) ref.read(bookshelfProvider.notifier).clearSelection();
}

class InvalidBookOverlay extends StatelessWidget {
  const InvalidBookOverlay({super.key});
  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: Container(
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: context.gtColors.scrim.withValues(alpha: .58),
        borderRadius: BorderRadius.circular(GtRadius.cover),
      ),
      child: const Text(
        '已失效',
        style: TextStyle(
          color: Colors.white,
          fontSize: 16,
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
  );
}
