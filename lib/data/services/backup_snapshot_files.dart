import 'dart:io';
import 'dart:isolate';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import '../../domain/models/backup_manifest.dart';
import 'backup_worker.dart';

Future<BackupEntry> hashBackupFile(String path, String base) async {
  final file = File(path);
  return BackupEntry(path: p.relative(path, from: base).replaceAll('\\', '/'),
    size: await file.length(), sha256: (await sha256.bind(file.openRead()).first).toString());
}

Future<BackupEntry> hashBackupFileInBackground(String path, String base) =>
    Isolate.run(() => hashBackupFile(path, base));

/// 一个后台任务完成全部文件的复制和哈希，避免每个小章节分别创建 isolate。
Future<List<BackupEntry>> copyBackupFiles(String sourceRoot, String targetRoot,
    List<String> paths, int total, SendPort progress, String cancel,
    {Map<String, String> external = const {}}) async {
  final entries = <BackupEntry>[await hashBackupFile(p.join(targetRoot, 'database', 'reader.sqlite'), targetRoot)];
  var done = 0;
  for (final path in [...paths, ...external.keys]) {
    checkBackupWorker(cancel);
    final target = File(p.join(targetRoot, external[path] ?? p.relative(path, from: sourceRoot)));
    await target.parent.create(recursive: true);
    final sink = target.openWrite();
    try {
      await for (final bytes in File(path).openRead()) {
        checkBackupWorker(cancel);
        sink.add(bytes); await sink.flush();
        progress.send(['复制书籍和资源', done += bytes.length, total]);
      }
    } finally { await sink.close(); }
    entries.add(await hashBackupFile(target.path, targetRoot));
  }
  checkBackupWorker(cancel);
  return entries;
}
