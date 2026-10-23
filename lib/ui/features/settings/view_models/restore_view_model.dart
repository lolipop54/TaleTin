import 'package:taletin/core/diagnostics/app_errors.dart';
import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/di/app_providers.dart';
import '../../../../app/runtime_scope.dart';
import '../../../../data/services/backup_import.dart';
import '../../../../domain/models/backup_operation.dart';
import '../../../../platform/channels/backup_documents.dart';

class RestoreViewState {
  const RestoreViewState({
    this.busy = false,
    this.message = '',
    this.preview,
    this.fraction,
    this.cancelled = false,
  });
  final bool busy;
  final String message;
  final BackupPreview? preview;
  final double? fraction;
  final bool cancelled;
}

final backupDocumentsProvider = Provider<BackupDocuments>(
  (_) => BackupDocuments(),
);
final restoreViewProvider =
    NotifierProvider.autoDispose<RestoreViewModel, RestoreViewState>(
      RestoreViewModel.new,
    );

class RestoreViewModel extends Notifier<RestoreViewState> {
  BackupPreview? _preview;
  BackupOperation? _operation;
  @override
  RestoreViewState build() {
    ref.onDispose(() {
      _operation?.cancelled = true;
      final preview = _preview;
      if (preview != null) {
        unawaited(preview.snapshot.directory.delete(recursive: true));
      }
    });
    return const RestoreViewState();
  }

  void cancel() {
    _operation?.cancelled = true;
  }

  Future<void> restore() async {
    if (state.busy || _preview == null) return;
    final snapshot = _preview!.snapshot;
    final restore = ref.read(restoreLibraryProvider);
    // 从这里开始暂存由应用交接流程负责，旧容器释放不能提前删除它。
    _preview = null;
    state = const RestoreViewState(busy: true, message: '正在交接书库，请等待完成');
    await restore(snapshot);
    if (ref.mounted) {
      state = const RestoreViewState(message: '当前书库未替换，请重新选择备份。');
    }
  }

  Future<void> inspect() async {
    if (state.busy) return;
    final operation = _operation = BackupOperation(
      onProgress: (phase, done, total) {
        state = RestoreViewState(
          busy: true,
          message: phase,
          preview: _preview,
          fraction: total > 0 ? (done / total).clamp(0.0, 1.0) : 0,
        );
      },
    );
    state = RestoreViewState(
      busy: true, message: '请选择备份文件', preview: _preview, fraction: 0,
    );
    try {
      final uri = await ref.read(backupDocumentsProvider).pick();
      if (uri == null) {
        state = RestoreViewState(cancelled: true, preview: _preview);
        return;
      }
      var reserve = 0;
      final root = Directory(ref.read(libraryRootPathProvider)).parent;
      for (final name in ['library', 'database', 'fonts']) {
        final dir = Directory('${root.path}/$name');
        if (await dir.exists()) {
          await for (final entity in dir.list(
            recursive: true,
            followLinks: false,
          )) {
            if (entity is File) reserve += await entity.length();
          }
        }
      }
      final next = await BackupImportService(
        Directory('${ref.read(cacheRootPathProvider)}/backup'),
        ref.read(documentPlatformProvider),
        reserveBytes: reserve,
      ).fromDocument(uri, operation);
      final previous = _preview;
      _preview = next;
      state = RestoreViewState(preview: next);
      if (previous != null) {
        await previous.snapshot.directory.delete(recursive: true);
      }
    } on BackupCancelled {
      state = RestoreViewState(preview: _preview, cancelled: true);
    } catch (error, appStack) {
      AppErrors.report(error, appStack, operation: '恢复备份失败');
      state = RestoreViewState(preview: _preview, message: '$error');
    } finally {
      state = RestoreViewState(
        preview: _preview,
        message: state.message,
        cancelled: state.cancelled,
      );
      _operation = null;
    }
  }
}
