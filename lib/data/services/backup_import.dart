import '../database/app_database.dart';

import 'dart:convert';
import 'dart:io';

import 'package:direct_read_rust/byte_processing.dart';

import '../../domain/models/backup_manifest.dart';
import '../../domain/models/backup_operation.dart';
import '../../domain/services/document_platform.dart';
import 'backup_snapshot.dart';
import 'backup_validation.dart';
import 'backup_worker.dart';
import 'backup_zip_reader.dart';
import 'backup_snapshot_files.dart';

class BackupPreview {
  const BackupPreview(
    this.snapshot,
    this.noteCount,
    this.originalDatabaseVersion,
  );
  final BackupSnapshot snapshot;
  final int noteCount, originalDatabaseVersion;
}

class BackupImportService {
  BackupImportService(this.work, this.platform, {this.reserveBytes = 0});
  final Directory work;
  final DocumentPlatform platform;
  final int reserveBytes;

  Future<BackupPreview> fromDocument(
    String uri,
    BackupOperation operation,
  ) async {
    operation.report('读取备份文件', 0, 1000);
    await work.create(recursive: true);
    final temp = await work.createTemp('incoming-');
    final file = File('${temp.path}/backup.zip');
    try {
      final session = await platform.open(uri);
      try {
        final total = session.sizeBytes ?? 0;
        if (total > BackupManifest.maxBytes + 256 * 1024 * 1024 ||
            await platform.availableBytes(work.path) <
                total + 32 * 1024 * 1024) {
          throw const FileSystemException('备份过大或暂存空间不足');
        }
        final sink = file.openWrite();
        var done = 0;
        try {
          while (true) {
            final bytes = await platform.readChunk(session, 1024 * 1024);
            if (bytes == null) break;
            done += bytes.length;
            if (done > BackupManifest.maxBytes + 256 * 1024 * 1024) {
              throw const FormatException('备份体积超限');
            }
            sink.add(bytes);
            await sink.flush();
            _InspectionStage(operation, 0, 200).report('读取备份文件', done, total);
          }
        } finally {
          await sink.close();
        }
      } finally {
        await platform.close(session);
      }
      return await fromFile(file, _InspectionStage(operation, 200, 1000));
    } finally {
      await temp.delete(recursive: true);
    }
  }

  Future<BackupPreview> fromFile(File file, BackupOperation operation) async {
    operation.report('检查备份清单', 0, 1000);
    await work.create(recursive: true);
    final staged = await work.createTemp('restore-');
    final root = staged.path, zipPath = file.path;
    try {
      final raw = await runBackupWorker(work, operation, (
        progress,
        cancel,
      ) async {
        final zip = BackupZipReader(zipPath);
        try {
          final manifestFile = File('$root/manifest.json');
          zip.extract(
            'manifest.json',
            manifestFile,
            zip.files['manifest.json']!.uncompressedSize,
            cancel,
          );
          return jsonDecode(await manifestFile.readAsString());
        } finally {
          zip.close();
        }
      });
      final manifest = BackupManifest.fromJson(
        raw,
        supportedDatabaseVersion: AppDatabase.currentSchemaVersion,
      );
      if (await platform.availableBytes(work.path) <
          manifest.totalBytes + reserveBytes + 32 * 1024 * 1024) {
        throw const FileSystemException('空间不足，无法解压并保留恢复前快照');
      }
      // 解压与哈希各按实际处理字节计量；全部校验结束前不会显示 100%。
      final fileProgress = _InspectionStage(operation, 50, 900);
      fileProgress.report('解压和校验书籍数据中', 0, manifest.totalBytes * 2);
      await runBackupWorker(work, fileProgress, (progress, cancel) async {
        final zip = BackupZipReader(zipPath);
        try {
          if (zip.files.length != manifest.files.length + 1) {
            throw const FormatException('ZIP 与清单的文件数量不一致');
          }
          var done = 0;
          for (final entry in manifest.files) {
            checkBackupWorker(cancel);
            final target = File('$root/${entry.path}');
            final extractedDigest = zip.extract(
              entry.path,
              target,
              entry.size,
              cancel,
              onProgress: (bytes) => progress.send([
                '解压和校验书籍数据中',
                done + bytes,
                manifest.totalBytes * 2,
              ]),
            );
            done += entry.size;
            if (extractedDigest != entry.sha256) {
              throw FormatException('文件校验失败：${entry.path}');
            }
            final input = target.openRead().map((bytes) {
              checkBackupWorker(cancel);
              progress.send([
                '解压和校验书籍数据中',
                done += bytes.length,
                manifest.totalBytes * 2,
              ]);
              return bytes;
            });
            final hash = NativeSha256();
            String writtenDigest;
            try {
              await for (final bytes in input) {
                hash.add(bytes);
              }
              writtenDigest = hash.finish();
            } finally {
              hash.close();
            }
            if (writtenDigest != entry.sha256) {
              throw FormatException('文件校验失败：${entry.path}');
            }
          }
        } finally {
          zip.close();
        }
      });
      operation.report('检查数据库与旧版本迁移', 900, 1000);
      final notes = await validateBackupDatabase(staged, manifest);
      operation.check();
      // 迁移可能改变数据库字节；暂存快照必须使用迁移后的大小与校验和。
      final dbFile = File('$root/database/reader.sqlite');
      operation.report('确认校验后的数据库', 950, 1000);
      final databaseEntry = await hashBackupFileInBackground(dbFile.path, root);
      final migrated = BackupManifest(
        databaseVersion: AppDatabase.currentSchemaVersion,
        createdAt: manifest.createdAt,
        bookCount: manifest.bookCount,
        storageVersion: manifest.storageVersion,
        files: [
          for (final entry in manifest.files)
            entry.path == databaseEntry.path ? databaseEntry : entry,
        ],
      );
      await File('$root/manifest.json')
          .writeAsString(jsonEncode(migrated.toJson()), flush: true);
      operation.report('校验完成', 1000, 1000);
      return BackupPreview(
        BackupSnapshot(staged, migrated),
        notes,
        manifest.databaseVersion,
      );
    } catch (_) {
      await staged.delete(recursive: true);
      rethrow;
    }
  }
}

/// 阶段占比用于整个流程的完成量，不代表剩余时间；取消仍由同一操作控制。
class _InspectionStage extends BackupOperation {
  _InspectionStage(this.parent, int start, int end)
    : super(
        onProgress: (phase, done, total) {
          final fraction = total > 0 ? (done / total).clamp(0.0, 1.0) : 0.0;
          // worker 的异步消息只更新显示；取消由分块检查和调用方检查抛出。
          parent.onProgress?.call(
            phase,
            start + ((end - start) * fraction).round(),
            1000,
          );
        },
      );
  final BackupOperation parent;
  @override
  bool get cancelled => parent.cancelled;
  @override
  set cancelled(bool value) => parent.cancelled = value;
}
