import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/di/app_providers.dart';
import '../../../../data/services/notes_export.dart';
import '../../../../data/services/backup_export.dart';
import '../../../../domain/models/backup_operation.dart';
import 'restore_view_model.dart';

class NotesExportState {
  const NotesExportState({this.busy = false, this.message = '', this.fraction});
  final bool busy;
  final String message;
  final double? fraction;
}

final notesExportProvider =
    NotifierProvider.autoDispose<NotesExportViewModel, NotesExportState>(
      NotesExportViewModel.new,
    );

class NotesExportViewModel extends Notifier<NotesExportState> {
  BackupOperation? _operation;
  @override
  NotesExportState build() {
    ref.onDispose(() {
      _operation?.cancelled = true;
    });
    return const NotesExportState();
  }

  void cancel() {
    _operation?.cancelled = true;
  }

  Future<void> export(NoteExportFormat format, String? bookId) async {
    if (state.busy) return;
    final documents = ref.read(backupDocumentsProvider);
    final writer = BackupExportService(
      documents,
      ref.read(documentPlatformProvider).availableBytes,
    );
    final service = NotesExportService(
      ref.read(appDatabaseProvider),
      Directory('${ref.read(cacheRootPathProvider)}/notes-export'),
      ref.read(chapterContentRepositoryProvider),
    );
    final operation = _operation = BackupOperation(
      onProgress: (phase, done, total) {
        if (ref.mounted) {
          state = NotesExportState(
            busy: true,
            message: phase,
            fraction: total > 0 ? (done / total).clamp(0.0, 1.0) : null,
          );
        }
      },
    );
    state = const NotesExportState(busy: true, message: '正在准备笔记');
    ExportedNotes? result;
    try {
      result = await service.create(format, operation, bookId: bookId);
      operation.check();
      final date = DateTime.now().toIso8601String().replaceAll(':', '-');
      final uri = await documents.create(
        '阅读笔记-$date.${format.extension}',
        format.mime,
      );
      if (uri == null) {
        if (ref.mounted) state = const NotesExportState(message: '已取消选择保存位置');
        return;
      }
      await writer.write(result.file, uri, operation);
      if (ref.mounted) {
        state = NotesExportState(message: '已完整导出 ${result.count} 条高亮和笔记。');
      }
    } catch (error) {
      if (ref.mounted) state = NotesExportState(message: '$error');
    } finally {
      if (result != null) await result.file.parent.delete(recursive: true);
      _operation = null;
      if (ref.mounted && state.busy) {
        state = NotesExportState(message: state.message);
      }
    }
  }
}
