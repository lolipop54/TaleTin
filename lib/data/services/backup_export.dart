import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive_io.dart';
import '../../domain/models/backup_operation.dart';
import '../../platform/channels/backup_documents.dart';
import 'backup_snapshot.dart';
import 'backup_worker.dart';
import 'backup_zip_writer.dart';

/// 先在私有目录完成打包，再写到用户选择的位置，成功必须等提供方关闭文件。
class BackupExportService {
  BackupExportService(this.documents, this.availableBytes);
  final BackupDocuments documents;
  final Future<int> Function(String) availableBytes;

  Future<File> pack(BackupSnapshot snapshot, BackupOperation operation) async {
    final root = snapshot.directory.path;
    final output = File('$root.zip');
    final total = snapshot.manifest.totalBytes;
    final largest = snapshot.manifest.files.fold(0, (a, b) => a > b.size ? a : b.size);
    final overhead = snapshot.manifest.files.fold(0, (a, b) => a + b.path.length * 8 + 256);
    if (await availableBytes(snapshot.directory.parent.path) <
        ((total + largest) * 1.002).ceil() + overhead + 64 * 1024 * 1024) {
      throw const FileSystemException('空间不足，无法打包完整备份');
    }
    final paths = ['manifest.json', ...snapshot.manifest.files.map((f) => f.path)];
    final outputPath = output.path;
    try {
      await runBackupWorker(snapshot.directory.parent, operation, (progress, cancel) async {
        final encoder = ZipFileEncoder();
        encoder.create(outputPath);
        var done = 0;
        try {
          for (final path in paths) {
            checkBackupWorker(cancel);
            final file = File('$root/$path');
            await addBackupFile(encoder, file, path, cancel, (bytes) {
              progress.send(['打包备份', done += bytes, total]);
            });
          }
        } finally { await encoder.close(); }
        checkBackupWorker(cancel);
      });
      operation.check();
      return output;
    } catch (_) {
      if (await output.exists()) await output.delete();
      rethrow;
    }
  }

  Future<void> write(File file, String uri, BackupOperation operation) async {
    try {
      await documents.open(uri);
      final total = await file.length();
      var done = 0;
      await for (final bytes in file.openRead()) {
        operation.report('写入所选位置', done, total);
        await documents.write(Uint8List.fromList(bytes));
        done += bytes.length;
      }
      operation.check();
      await documents.finish();
      operation.onProgress?.call('备份已保存', total, total);
    } catch (error) {
      var removed = false;
      try { removed = await documents.abort(uri); } catch (_) { /* 下方报告残留。 */ }
      if (!removed) throw FileSystemException('$error；未完整文件未能删除，请手动删除', uri);
      rethrow;
    }
  }
}
