import 'package:taletin/core/diagnostics/app_errors.dart';
import 'package:taletin/ui/core/widgets/gt_dialog_action.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/di/completion_providers.dart';
import '../../../../domain/models/book_completion.dart';
import '../view_models/reader_session_view_model.dart';
import '../view_models/reader_view_model.dart';
import '../view_models/automatic_reading.dart';

/// 手动命令与书末确认共用一个保存流程；只有明确确认后才写完成记录。
Future<void> confirmBookCompletion(
  BuildContext context,
  WidgetRef ref,
  String bookId, {
  bool atEnd = false,
}) async {
  final session = ref.read(readerSessionProvider(bookId)).value;
  if (session == null) return;
  await ref.read(automaticReadingProvider(bookId).notifier).pause();
  final repository = ref.read(bookCompletionRepositoryProvider);
  try {
    final completed = (await repository.load()).any(
      (r) => r.bookId == bookId && r.active,
    );
    if (!context.mounted || (atEnd && completed)) return;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(
          completed
              ? '撤销已读？'
              : atEnd
              ? '这本书读完了吗？'
              : '标为已读？',
        ),
        content: Text(
          '《${session.book.title}》\n${completed ? '撤销后不计入已读本数，已经解锁的徽章保留。' : '仅在您确认后记为读完；阅读位置不会改变。'}',
        ),
        actions: [
          GtDialogAction(onPressed: () => Navigator.pop(c, false), label: '暂不'),
          GtDialogAction(
            onPressed: () => Navigator.pop(c, true),
            role: completed
                ? GtDialogActionRole.neutral
                : GtDialogActionRole.primary,
            label: completed ? '撤销已读' : '确认已读',
          ),
        ],
      ),
    );
    if (accepted != true) return;
    if (completed) {
      await repository.revoke(bookId);
    } else {
      await repository.mark(
        bookId,
        session.book.title,
        atEnd ? CompletionSource.endConfirm : CompletionSource.manual,
      );
    }
    if (context.mounted) {
      ref
          .read(readerProvider.notifier)
          .showNotice(completed ? '已撤销完成记录' : '已记入已读书籍');
    }
  } catch (appError, appStack) {
    AppErrors.report(appError, appStack, operation: '完成阅读记录未保存');
    if (context.mounted) {
      ref.read(readerProvider.notifier).showNotice('完成记录未保存，请重试');
    }
  }
}

class CompletionPromptHost extends ConsumerStatefulWidget {
  const CompletionPromptHost({super.key, required this.bookId});
  final String bookId;
  @override
  ConsumerState<CompletionPromptHost> createState() =>
      _CompletionPromptHostState();
}

class _CompletionPromptHostState extends ConsumerState<CompletionPromptHost> {
  bool prompted = false;
  @override
  Widget build(BuildContext context) {
    ref.listen(readerProvider.select((s) => s.noticeToken), (_, _) {
      final notice = ref.read(readerProvider).notice;
      if (prompted || (notice != '已经是最后一页了' && notice != '已到全书末尾')) return;
      prompted = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          confirmBookCompletion(context, ref, widget.bookId, atEnd: true);
        }
      });
    });
    return const SizedBox.shrink();
  }
}
