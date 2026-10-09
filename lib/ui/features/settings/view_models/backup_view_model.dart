import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/di/app_providers.dart';
import '../../../../app/di/statistics_providers.dart';
import '../../../../data/services/backup_snapshot.dart';
import '../../../../data/services/backup_export.dart';
import '../../../../domain/models/backup_operation.dart';
import '../../../../platform/channels/backup_documents.dart';
import '../../../../data/services/saved_backups.dart';

final savedBackupsProvider = FutureProvider.autoDispose<List<BackupSnapshot>>(
  (ref) => SavedBackups(
    Directory(
      '${Directory(ref.watch(libraryRootPathProvider)).parent.path}/backups',
    ),
  ).list(),
);

class BackupViewState {
  const BackupViewState({
    this.busy = false,
    this.canCancel = true,
    this.message = '',
    this.done = 0,
    this.total = 0,
    this.snapshot,
  });
  final bool busy;
  final bool canCancel;
  final String message;
  final int done, total;
  final BackupSnapshot? snapshot;
}

final backupViewProvider =
    NotifierProvider.autoDispose<BackupViewModel, BackupViewState>(
      BackupViewModel.new,
    );

class BackupViewModel extends Notifier<BackupViewState> {
  BackupOperation? _operation;
  BackupSnapshot? _snapshot;
  final documents = BackupDocuments();
  @override
  BackupViewState build() {
    ref.onDispose(() {
      _operation?.cancelled = true;
      final snapshot = _snapshot;
      if (snapshot != null) {
        unawaited(snapshot.directory.delete(recursive: true));
      }
    });
    return const BackupViewState();
  }

  void cancel() {
    _operation?.cancelled = true;
  }

  Future<void> _run(
    Future<void> Function(BackupOperation) action, {
    bool canCancel = true,
    String message = '正在准备',
  }) async {
    if (state.busy) return;
    _operation = BackupOperation(
      onProgress: (phase, done, total) {
        state = BackupViewState(
          busy: true,
          canCancel: canCancel,
          message: phase,
          done: done,
          total: total,
          snapshot: state.snapshot,
        );
      },
    );
    state = BackupViewState(
      busy: true,
      canCancel: canCancel,
      message: message,
      snapshot: state.snapshot,
    );
    try {
      await action(_operation!);
    } catch (error) {
      state = BackupViewState(snapshot: state.snapshot, message: '$error');
    } finally {
      state = BackupViewState(snapshot: state.snapshot, message: state.message);
      _operation = null;
    }
  }

  Future<void> deleteSaved(BackupSnapshot snapshot) => _run(
    (_) async {
      final directory = Directory(
        '${Directory(ref.read(libraryRootPathProvider)).parent.path}/backups',
      );
      await SavedBackups(directory).delete(snapshot);
      // 刷新完成才解除操作锁；读取期间继续显示原列表，避免先清空再出现。
      ref.invalidate(savedBackupsProvider);
      await ref.read(savedBackupsProvider.future);
      state = BackupViewState(snapshot: state.snapshot, message: '自动快照已删除');
    },
    canCancel: false,
    message: '正在删除快照',
  );

  Future<void> prepare() => _run((operation) async {
    final release = await ref.read(automaticReadingTasksProvider).suspendAll();
    try {
      await ref.read(listeningAudioHandlerProvider).pause();
      await ref.read(readingPositionCoordinatorProvider).flush();
      await ref.read(readingStatisticsServiceProvider).flush();
      final service = BackupSnapshotService(
        database: ref.read(appDatabaseProvider),
        root: Directory(ref.read(libraryRootPathProvider)).parent,
        work: Directory('${ref.read(cacheRootPathProvider)}/backup'),
        gate: ref.read(libraryFileGateProvider),
        availableBytes: ref.read(documentPlatformProvider).availableBytes,
      );
      final next = await service.create(operation);
      _snapshot = next;
      final old = state.snapshot;
      state = BackupViewState(busy: true, snapshot: next);
      if (old != null) await old.directory.delete(recursive: true);
    } finally {
      release();
    }
  });

  Future<void> save([BackupSnapshot? saved]) => _run((operation) async {
    final snapshot = saved ?? state.snapshot!;
    final service = BackupExportService(
      documents,
      ref.read(documentPlatformProvider).availableBytes,
    );
    final file = await service.pack(snapshot, operation);
    try {
      operation.check();
      final date = snapshot.manifest.createdAt
          .toLocal()
          .toIso8601String()
          .replaceAll(':', '-');
      final uri = await documents.create('TaleTin-$date.zip', 'application/zip');
      if (uri == null) {
        state = BackupViewState(
          snapshot: state.snapshot,
          message: '已取消选择保存位置，快照仍可重新保存。',
        );
        return;
      }
      await service.write(file, uri, operation);
      state = BackupViewState(snapshot: state.snapshot, message: '备份已完整保存。');
    } finally {
      if (await file.exists()) await file.delete();
    }
  });
}
