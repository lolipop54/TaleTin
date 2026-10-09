import 'dart:io' as io;
import 'package:archive/archive_io.dart';
import 'backup_worker.dart';

/// archive 默认把单文件压缩结果放内存；这里先流式压到磁盘，再写入 ZIP。
Future<void> addBackupFile(ZipFileEncoder encoder, io.File source, String name,
    String cancelPath, void Function(int) onBytes) async {
  final compressed = io.File('$cancelPath.deflate');
  var crc = 0;
  try {
    await source.openRead().map((bytes) {
      checkBackupWorker(cancelPath);
      crc = getCrc32(bytes, crc); onBytes(bytes.length); return bytes;
    }).transform(io.ZLibEncoder(raw: true)).pipe(compressed.openWrite());
    checkBackupWorker(cancelPath);
    final content = _CompressedFile(InputFileStream(compressed.path));
    try {
      encoder.addArchiveFile(ArchiveFile.file(name, await source.length(), content)
        ..compression = CompressionType.deflate ..crc32 = crc);
    } finally { await content.close(); }
  } finally { if (await compressed.exists()) await compressed.delete(); }
}

class _CompressedFile extends FileContentStream {
  _CompressedFile(super.stream);
  @override
  bool get isCompressed => true;
}
