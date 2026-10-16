import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../domain/models/backup_manifest.dart';
import '../../domain/models/backup_operation.dart';
import '../../domain/services/library_file_gate.dart';
import '../database/app_database.dart';
import 'backup_worker.dart';
import 'backup_snapshot_files.dart';
import 'backup_validation.dart';

class BackupSnapshot {
  const BackupSnapshot(this.directory, this.manifest);
  final Directory directory;
  final BackupManifest manifest;
}

/// 只复制持久数据；调用方先结算听书、位置与统计，再进入这个快照时点。
class BackupSnapshotService {
  BackupSnapshotService({
    required this.database,
    required this.root,
    required this.work,
    required this.gate,
    required this.availableBytes,
  });
  final AppDatabase database;
  final Directory root, work;
  final LibraryFileGate gate;
  final Future<int> Function(String path) availableBytes;

  Future<BackupSnapshot> create(
    BackupOperation operation, {
    bool filesAlreadyFrozen = false,
  }) async {
    operation.report('等待导入和删除完成', 0, 0);
    final release = filesAlreadyFrozen ? () {} : await gate.freeze();
    Directory? target;
    try {
      operation.check();
      final sources = <File>[];
      final external = <String, String>{};
      final missing = <String>[];
      final linked = <String>{};
      var total = 0;
      for (final book in await database.select(database.books).get()) {
        if (book.status == 'removed' || !book.sourceHash.startsWith('file:')) {
          continue;
        }
        linked.add(book.id);
        final path = Uri.parse(book.sourceHash).toFilePath();
        final file = File(path);
        if ((book.status == 'active' || book.status == 'preparing') && await file.exists()) {
          external[path] = 'library/${book.id}/source.${book.format}';
          total += await file.length();
        } else {
          missing.add(book.id);
        }
      }
      for (final name in ['library', 'fonts']) {
        final directory = Directory(p.join(root.path, name));
        if (!await directory.exists()) continue;
        await for (final entity in directory.list(
          recursive: true,
          followLinks: false,
        )) {
          operation.check();
          if (entity is Link) {
            throw const FileSystemException('持久数据目录包含链接，无法安全备份');
          }
          if (entity is File) {
            final parts = p.split(p.relative(entity.path, from: root.path));
            // 路径记录不能指回旧手机；原书由上面的有效来源名单单独加入。
            if (parts.length == 3 &&
                parts.first == 'library' &&
                linked.contains(parts[1]) &&
                parts.last.startsWith('source.')) {
              continue;
            }
            sources.add(entity);
            total += await entity.length();
          }
        }
      }
      if (sources.length + external.length + 1 > BackupManifest.maxFiles ||
          total > BackupManifest.maxBytes) {
        throw const FormatException('备份超过 20 万文件或 32 GiB 支持范围');
      }
      await work.create(recursive: true);
      var databaseBytes = 0;
      for (final suffix in ['', '-wal']) {
        final file = File(
          p.join(root.path, 'database', 'reader.sqlite$suffix'),
        );
        if (await file.exists()) databaseBytes += await file.length();
      }
      if (await availableBytes(work.path) <
          total + databaseBytes * 2 + 32 * 1024 * 1024) {
        throw const FileSystemException('空间不足，无法创建完整快照');
      }
      target = await work.createTemp('snapshot-');
      final dbFile = File(p.join(target.path, 'database', 'reader.sqlite'));
      await dbFile.parent.create(recursive: true);
      operation.report('生成数据库快照', 0, total);
      await database.customStatement('VACUUM INTO ?', [dbFile.path]);
      // 显式同步输出，避免依赖不同 SQLite 版本的 VACUUM fsync 行为。
      final handle = await dbFile.open(mode: FileMode.append);
      try {
        await handle.flush();
      } finally {
        await handle.close();
      }
      final snapshotDb = AppDatabase.openFile(dbFile);
      late int bookCount;
      try {
        for (final id in missing) {
          await snapshotDb.customStatement(
            "UPDATE books SET status = 'contentMissing' WHERE id = ?",
            [id],
          );
        }
        bookCount =
            (await snapshotDb
                    .customSelect(
                      "SELECT COUNT(*) AS n FROM books WHERE status <> 'removed'",
                    )
                    .getSingle())
                .read<int>('n');
        if ((await snapshotDb
                        .customSelect('PRAGMA integrity_check')
                        .getSingle())
                    .data
                    .values
                    .single !=
                'ok' ||
            (await snapshotDb.customSelect('PRAGMA foreign_key_check').get())
                .isNotEmpty) {
          throw const FormatException('数据库快照完整性检查失败');
        }
      } finally {
        await snapshotDb.close();
      }
      final sourceRoot = root.path, targetRoot = target.path;
      final paths = sources.map((file) => file.path).toList();
      final entries = await runBackupWorker(
        work,
        operation,
        (progress, cancel) => copyBackupFiles(
          sourceRoot,
          targetRoot,
          paths,
          total,
          progress,
          cancel,
          external: external,
        ),
      );
      final manifest = BackupManifest(
        databaseVersion: database.schemaVersion,
        createdAt: DateTime.now().toUtc(),
        bookCount: bookCount,
        files: entries,
      );
      // 创建与恢复共用校验规则，不能导出一个自己无法恢复的备份。
      BackupManifest.fromJson(
        manifest.toJson(),
        supportedDatabaseVersion: database.schemaVersion,
      );
      await validateBackupDatabase(target, manifest);
      final manifestFile = File(p.join(target.path, 'manifest.json.next'));
      await manifestFile.writeAsString(
        jsonEncode(manifest.toJson()),
        flush: true,
      );
      await manifestFile.rename(p.join(target.path, 'manifest.json'));
      return BackupSnapshot(target, manifest);
    } catch (_) {
      if (target != null && await target.exists()) {
        await target.delete(recursive: true);
      }
      rethrow;
    } finally {
      release();
    }
  }
}
