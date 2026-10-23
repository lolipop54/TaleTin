import 'package:taletin/core/diagnostics/app_errors.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../../domain/models/annotation.dart';
import '../../../../../data/services/annotation_locator_service.dart';
import '../../views/reader_view.dart' show NoteEditorPanel;
import '../../view_models/reader_session_view_model.dart';
import '../../view_models/reader_progress_return.dart';
import '../../view_models/original_layout_controller.dart';
import '../../view_models/reader_view_model.dart';

/// 先保留旧正文，等定位、选段和平台画面准备好后，再淡化交接。
Future<void> jumpToBookNote(
  WidgetRef ref,
  String bookId,
  Annotation note,
) async {
  final vm = ref.read(readerProvider.notifier);
  final session = ref.read(readerSessionProvider(bookId).notifier);
  final hold = session.usesOriginalWebView
      ? ref.read(originalLayoutProvider(bookId)).value?.holdPageDuringJump
      : null;
  Future<void> jump() async {
    vm.closePanel(collapseControls: true);
    if (hold != null) {
      await hold(() => session.goToAnnotation(note));
    } else {
      await session.goToAnnotation(note);
    }
  }

  try {
    // 原书的临时截图要先撤下，再淡出正文旧图，否则会露出同一张旧页。
    await ref.read(readerProgressReturnProvider(bookId).notifier).jump(jump);
  } catch (error, appStack) {
    AppErrors.report(error, appStack, operation: '定位笔记失败');
    vm.showNotice(
      error is AnnotationLocationFailure ? error.message : '定位失败，请重试',
    );
  }
}

/// 跨书列表也复用现有草稿、保存及放弃修改确认，不另写一套编辑规则。
Future<void> editLibraryNote(
  BuildContext context,
  WidgetRef ref,
  Annotation note,
) async {
  final vm = ref.read(readerProvider.notifier);
  vm.openNoteEditor(
    NoteEditorRequest(
      range: note.range,
      quote: note.quote,
      chapterTitle: note.chapterTitle,
      existing: note,
    ),
  );
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => Consumer(
      builder: (context, ref, _) {
        ref.listen(readerProvider.select((state) => state.note), (_, next) {
          if (next == null && context.mounted) Navigator.pop(context);
        });
        return PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) vm.requestCloseNoteEditor();
          },
          child: Dialog(
            insetPadding: EdgeInsets.zero,
            backgroundColor: Colors.transparent,
            child: Align(
              alignment: Alignment.bottomCenter,
              child: NoteEditorPanel(
                bookId: note.bookId,
                request:
                    ref.watch(readerProvider).note ??
                    NoteEditorRequest(
                      range: note.range,
                      quote: note.quote,
                      chapterTitle: note.chapterTitle,
                      existing: note,
                    ),
              ),
            ),
          ),
        );
      },
    ),
  );
}
