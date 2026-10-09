import '../database/app_database.dart';

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../domain/models/backup_manifest.dart';
import 'backup_snapshot.dart';

/// 自动快照在私有持久目录保留，不随页面退出或普通清缓存删除。
class SavedBackups {
  SavedBackups(this.root);
  final Directory root;
  Future<void> delete(BackupSnapshot snapshot) async {
    final target = p.normalize(snapshot.directory.absolute.path);
    final base = p.normalize(root.absolute.path);
    // 删除只允许快照目录的直接子目录，不接受书库、父目录或目录链接。
    if (!p.equals(p.dirname(target), base) ||
        await FileSystemEntity.type(target, followLinks: false) !=
            FileSystemEntityType.directory) {
      throw FileSystemException('快照位置无效，未删除', target);
    }
    await Directory(target).delete(recursive: true);
  }

  Future<List<BackupSnapshot>> list() async {
    if (!await root.exists()) return [];
    final snapshots = <BackupSnapshot>[];
    await for (final entry in root.list(followLinks: false)) {
      if (entry is! Directory) continue;
      final file = File('${entry.path}/manifest.json');
      // 只有最后写完清单才算完整快照；强杀留下的半成品不能供用户导出。
      if (!await file.exists()) continue;
      final manifest = BackupManifest.fromJson(
        jsonDecode(await file.readAsString()),
        supportedDatabaseVersion: AppDatabase.currentSchemaVersion,
      );
      snapshots.add(BackupSnapshot(entry, manifest));
    }
    snapshots.sort(
      (a, b) => b.manifest.createdAt.compareTo(a.manifest.createdAt),
    );
    return snapshots;
  }
}
