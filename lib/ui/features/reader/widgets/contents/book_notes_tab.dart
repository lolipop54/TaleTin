import 'package:taletin/core/diagnostics/app_errors.dart';
import 'package:taletin/ui/core/widgets/gt_dialog_action.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../../app/di/app_providers.dart';
import '../../../../../domain/models/annotation.dart';
import '../../../../core/theme/gt_tokens.dart';
import '../../../../core/theme/reading_theme.dart';
import '../../../../core/widgets/gt_icon.dart';
import '../../../../core/widgets/state_views.dart';
import '../../view_models/reader_session_view_model.dart';
import '../../view_models/annotation_list_provider.dart';
import '../../view_models/reader_view_model.dart';
import 'note_tab.dart';
import 'note_actions.dart';

/// 只展示已保存的标注；草稿不计入列表，首批数据到达前不显示空态。
class BookNotesTab extends ConsumerStatefulWidget {
  const BookNotesTab({super.key, required this.bookId, required this.query});

  final String bookId;
  final String query;

  @override
  ConsumerState<BookNotesTab> createState() => _BookNotesTabState();
}

class _BookNotesTabState extends ConsumerState<BookNotesTab> {
  String get bookId => widget.bookId;
  String get query => widget.query;
  List<Annotation>? _visible;
  @override
  void didUpdateWidget(covariant BookNotesTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.bookId != bookId) _visible = null;
  }

  @override
  Widget build(BuildContext context) {
    final result = ref.watch(annotationsProvider(bookId));
    if (result.hasError) {
      return GtErrorView(
        title: '笔记读取失败',
        onRetry: () => ref.invalidate(annotationsProvider(bookId)),
      );
    }
    final notes = result.value;
    if (notes == null) return const GtLoadingView(label: '正在读取笔记…');
    final keyword = query.trim().toLowerCase();
    final prepared = ref.watch(noteListProvider((notes, query)));
    if (prepared.hasValue) _visible = prepared.requireValue;
    if (_visible == null) return const GtLoadingView(label: '正在读取笔记…');
    final visible = _visible!;
    if (visible.isEmpty) {
      return GtEmptyView(
        icon: GtIcons.note,
        title: keyword.isEmpty ? '还没有笔记' : '没有匹配的笔记',
        message: keyword.isEmpty ? '长按正文选择文字，可高亮或写想法' : '换个关键词试试',
      );
    }
    return ListView.builder(
      shrinkWrap: true,
      padding: const EdgeInsets.symmetric(horizontal: GtSpacing.s4),
      itemCount: visible.length,
      itemBuilder: (context, index) {
        final note = visible[index];
        return ReaderAnnotationItem(
          key: ValueKey(note.id),
          chipLabel: note.color?.label ?? '文字笔记',
          chipColor: highlightColorOf(note.color),
          date: annotationDate(note.updatedAt),
          quote: note.quote,
          body: note.body,
          quoteHighlight: note.color == null
              ? null
              : pageHighlightColorOf(note.color),
          location: note.chapterTitle,
          onJump: () => jumpToBookNote(ref, bookId, note),
          onEdit: () {
            final vm = ref.read(readerProvider.notifier);
            vm.closePanel();
            vm.openNoteEditor(
              NoteEditorRequest(
                range: note.range,
                quote: note.quote,
                chapterTitle: note.chapterTitle,
                existing: note,
              ),
            );
          },
          onDelete: () => deleteNote(context, ref, note),
        );
      },
    );
  }
}

String annotationDate(DateTime time) {
  final local = time.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${local.year}-${local.month.toString().padLeft(2, '0')}-'
      '${two(local.day)} ${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
}

/// 删除前明确询问；数据库提交失败时条目仍保留，并显示可读的原因。
Future<void> deleteNote(
  BuildContext context,
  WidgetRef ref,
  Annotation note,
) async {
  final repository = ref.read(annotationRepositoryProvider);
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('删除这条笔记？'),
      content: const Text('摘录、想法和正文中的高亮会一起删除。'),
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
  if (confirmed != true) return;
  try {
    await repository.deleteAnnotation(note.id);
  } catch (appError, appStack) {
    AppErrors.report(appError, appStack, operation: '删除笔记失败', notify: false);
    if (context.mounted) {
      AppErrors.report(appError, appStack, operation: '删除笔记失败');
    }
  }
}
