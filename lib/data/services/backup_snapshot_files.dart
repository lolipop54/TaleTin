import 'dart:io';
import 'dart:isolate';

import 'package:direct_read_rust/byte_processing.dart';
import 'package:path/path.dart' as p;

import '../../domain/models/backup_manifest.dart';
import 'backup_worker.dart';

Future<BackupEntry> hashBackupFile(String path, String base) async {
  final file = File(path);
  return BackupEntry(
    path: p.relative(path, from: base).replaceAll('\\', '/'),
    size: await file.length(),
    sha256: await nativeFileDigest(path),
  );
}

Future<BackupEntry> hashBackupFileInBackground(String path, String base) =>
    Isolate.run(() => hashBackupFile(path, base));

/// 一个后台任务完成全部文件的复制和哈希，避免每个小章节分别创建 isolate。
Future<List<BackupEntry>> copyBackupFiles(
  String sourceRoot,
  String targetRoot,
  List<String> paths,
  int total,
  SendPort progress,
  String cancel, {
  Map<String, String> external = const {},
}) async {
  final entries = <BackupEntry>[
    await hashBackupFile(
      p.join(targetRoot, 'database', 'reader.sqlite'),
      targetRoot,
    ),
  ];
  var done = 0;
  for (final path in [...paths, ...external.keys]) {
    checkBackupWorker(cancel);
    final target = File(
      p.join(targetRoot, external[path] ?? p.relative(path, from: sourceRoot)),
    );
    await target.parent.create(recursive: true);
    final sink = target.openWrite();
    final hash = NativeSha256();
    var reported = done;
    late String copiedDigest;
    try {
      // addStream keeps filesystem backpressure; no per-chunk flush or whole-file buffer.
      await sink.addStream(
        File(path).openRead().map((bytes) {
          checkBackupWorker(cancel);
          hash.add(bytes);
          done += bytes.length;
          if (done - reported >= 256 * 1024) {
            progress.send(['复制书籍和资源', done, total]);
            reported = done;
          }
          return bytes;
        }),
      );
      copiedDigest = hash.finish();
    } finally {
      try {
        await sink.close();
      } finally {
        hash.close();
      }
    }
    checkBackupWorker(cancel);
    // Keep the target reread: the bytes accepted by the sink alone are not a file check.
    final entry = await hashBackupFile(target.path, targetRoot);
    if (entry.sha256 != copiedDigest) {
      throw FileSystemException('备份副本校验失败', target.path);
    }
    entries.add(entry);
    progress.send(['复制书籍和资源', done, total]);
  }
  checkBackupWorker(cancel);
  return entries;
}
