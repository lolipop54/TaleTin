import 'dart:io';
import '../data/services/backup_snapshot.dart';
import '../data/services/backup_restore_transaction.dart';
import '../data/services/restore_book_sources.dart';
import '../domain/models/backup_operation.dart';
import 'bootstrap.dart';

class RestoredRuntime {
  const RestoredRuntime(this.runtime, this.message, this.restored);
  final BootstrapResult runtime;
  final String message;
  final bool restored;
}

/// UI 负责阻止新操作并等待导入；这里负责持久快照、目录事务和运行服务交接。
Future<RestoredRuntime> restoreRuntime(BootstrapResult current, BackupSnapshot incoming, {
  required Future<void> Function() releaseUi,
  required Future<void> Function(BootstrapResult) prepareUi,
  required Future<int> Function(String) availableBytes,
  void Function(String)? progress,
  Future<void> Function(String)? onBoundary,
}) async {
  final root = Directory(current.libraryRoot).parent;
  final transaction = BackupRestoreTransaction(root, onBoundary: onBoundary);
  final releaseAutomatic = await current.automaticTasks.suspendAll();
  void Function()? releaseFiles;
  void Function()? releaseMedia;
  BootstrapResult? next;
  var closed = false;
  try {
    releaseMedia = await current.listeningHandler.suspendForRestore();
    progress?.call('等待文件操作结束');
    releaseFiles = await current.fileGate.freeze();
    await current.positions.flush();
    await current.statistics.flush();
    await current.achievements.refresh();
    progress?.call('保存恢复前的自动快照');
    await BackupSnapshotService(database: current.database, root: root,
      work: Directory('${root.path}/backups'), gate: current.fileGate,
      availableBytes: availableBytes).create(BackupOperation(onProgress: (phase, _, _) => progress?.call(phase)),
        filesAlreadyFrozen: true);
    await onBoundary?.call('snapshot-ready');
    await releaseUi();
    await current.close();
    closed = true;
    await onBoundary?.call('services-closed');
    progress?.call('替换书库数据');
    await restoreBookSources(incoming.directory, root);
    await transaction.replace(incoming.directory);
    await onBoundary?.call('before-initialize');
    // 原书缓存按书号和版本命名；不同备份可能同号同版但内容不同，必须丢弃。
    final originalCache = Directory('${current.cacheRoot}/original');
    if (await originalCache.exists()) await originalCache.delete(recursive: true);
    next = await prepareApp(supportRoot: root, cacheRoot: Directory(current.cacheRoot), recoverPending: false);
    await prepareUi(next);
    await onBoundary?.call('before-commit');
    await transaction.commit();
    return RestoredRuntime(next, '恢复完成。恢复前的书库已保存为自动快照。', true);
  } catch (error) {
    if (!closed) rethrow; // 尚未释放旧界面，也没有替换任何正式文件。
    await next?.close();
    progress?.call('恢复未完成，正在重新打开完整书库');
    // 已提交记录保留新状态；未提交记录恢复原状态，和下次冷启动口径一致。
    final committed = await transaction.isCommitted();
    await transaction.recover();
    final reopened = await prepareApp(supportRoot: root, cacheRoot: Directory(current.cacheRoot));
    await prepareUi(reopened);
    return RestoredRuntime(reopened, committed
      ? '书库已恢复，清理时发生错误：$error'
      : '恢复没有完成，已回到原书库：$error', committed);
  } finally {
    releaseFiles?.call(); releaseMedia?.call(); releaseAutomatic();
    if (await incoming.directory.exists()) await incoming.directory.delete(recursive: true);
  }
}
