import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../app/di/app_providers.dart';
import '../../../../app/router/app_router.dart';
import '../../../../domain/models/book.dart';
import '../../../../platform/channels/system_toast.dart';
import '../../../../core/diagnostics/reader_work_trace.dart';
import '../../../core/theme/gt_tokens.dart';
import '../../../core/widgets/gt_dialog_action.dart';
import '../view_models/bookshelf_view_model.dart';

/// 点击前再查一次，覆盖外部删除尚未被书架轮询发现的间隙。
Future<void> openShelfBook(
  BuildContext context,
  WidgetRef ref,
  Book book,
) async {
  BookOpeningTrace.begin(
    book.id,
    entry: 'shelf',
    details: {
      'format': book.format.code,
      'status': book.status.code,
      'bytes': book.sizeBytes,
    },
  );
  final repository = ref.read(bookRepositoryProvider);
  final current = await traceReaderWork(
    'shelf.open.lookup',
    () => repository.findById(book.id),
    {'bookId': book.id},
  );
  BookOpeningTrace.mark(book.id, 'shelf_lookup');
  if (!context.mounted ||
      current == null ||
      current.status == BookStatus.removed) {
    BookOpeningTrace.finish(book.id, status: 'unavailable');
    return;
  }
  if (current.status == BookStatus.active ||
      current.status == BookStatus.sourceChanged ||
      current.status == BookStatus.preparing) {
    BookOpeningTrace.mark(book.id, 'navigation_requested');
    context.push(AppRoutes.reader(book.id));
    return;
  }
  BookOpeningTrace.finish(book.id, status: 'invalid_source');
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
  final result = await ref
      .read(deleteBooksProvider)
      .run(ids, now: DateTime.now().toUtc());
  if (context.mounted) {
    ref.read(bookshelfProvider.notifier).pruneSelection(result.undeletedIds);
    if (result.undeletedIds.isNotEmpty) {
      await SystemToast.show('${result.undeletedIds.length} 本未删除，请重试');
    }
  }
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
