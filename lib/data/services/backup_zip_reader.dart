import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:archive/archive_io.dart';
import '../../domain/models/backup_manifest.dart';
import 'backup_worker.dart';

/// 先限制目录条目，再打开内容；不让通用 ZIP 解码器提前解压符号链接。
class BackupZipReader {
  BackupZipReader(String path) : input = InputFileStream(path) {
    try { _readDirectory(); } catch (_) { input.closeSync(); rethrow; }
  }
  final InputFileStream input;
  final Map<String, ZipFileHeader> files = {};
  static const manifestLimit = 32 * 1024 * 1024;

  void _readDirectory() {
    final tailSize = min(input.length, 65557);
    final tail = input.subset(position: input.length - tailSize, length: tailSize).toUint8List();
    final data = ByteData.sublistView(tail);
    var end = -1;
    for (var i = tail.length - 22; i >= 0; i--) {
      if (data.getUint32(i, Endian.little) == 0x06054b50 &&
          i + 22 + data.getUint16(i + 20, Endian.little) == tail.length) { end = i; break; }
    }
    if (end < 0) throw const FormatException('ZIP 目录不完整');
    if (data.getUint16(end + 4, Endian.little) != 0 || data.getUint16(end + 6, Endian.little) != 0) {
      throw const FormatException('不支持分卷备份');
    }
    var count = data.getUint16(end + 10, Endian.little);
    var size = data.getUint32(end + 12, Endian.little);
    var offset = data.getUint32(end + 16, Endian.little);
    final endPosition = input.length - tailSize + end;
    if (count == 0xffff || size == 0xffffffff || offset == 0xffffffff) {
      input.setPosition(endPosition - 20);
      if (input.readUint32() != 0x07064b50 || input.readUint32() != 0) throw const FormatException('ZIP64 目录损坏');
      final zip64 = input.readUint64();
      if (input.readUint32() != 1 || zip64 < 0 || zip64 + 56 > endPosition) throw const FormatException('ZIP64 范围无效');
      input.setPosition(zip64);
      if (input.readUint32() != 0x06064b50) throw const FormatException('ZIP64 标记损坏');
      input.skip(12);
      if (input.readUint32() != 0 || input.readUint32() != 0) throw const FormatException('不支持分卷备份');
      input.skip(8); count = input.readUint64(); size = input.readUint64(); offset = input.readUint64();
    }
    if (count < 1 || count > BackupManifest.maxFiles + 1 || offset < 0 || size < 0 ||
        size > 256 * 1024 * 1024 || offset + size > endPosition) {
      throw const FormatException('ZIP 目录体积或文件数量无效');
    }
    final directory = input.subset(position: offset, length: size);
    final seen = <String>{};
    var total = 0;
    for (var i = 0; i < count; i++) {
      if (directory.length < 46 || directory.readUint32() != ZipFileHeader.signature) throw const FormatException('ZIP 文件目录损坏');
      final header = ZipFileHeader()..read(directory);
      final name = header.filename;
      final limit = name == 'manifest.json' ? manifestLimit : BackupManifest.maxBytes;
      if ((name != 'manifest.json' && !BackupEntry.isSafePath(name)) || !seen.add(name) ||
          (header.externalFileAttributes >> 16 & 0xf000) == 0xa000 ||
          header.generalPurposeBitFlag & 0x41 != 0 || ![0, 8].contains(header.compressionMethod) ||
          header.compressedSize < 0 || header.compressedSize > input.length ||
          header.uncompressedSize < 0 || header.uncompressedSize > limit ||
          header.localHeaderOffset < 0 || header.localHeaderOffset + 30 > offset) {
        throw const FormatException('ZIP 含越界、重复、加密、链接或超限文件');
      }
      total += header.uncompressedSize;
      if (total > BackupManifest.maxBytes + manifestLimit) throw const FormatException('ZIP 解压体积超限');
      files[name] = header;
    }
    if (!directory.isEOS || !files.containsKey('manifest.json')) throw const FormatException('ZIP 清单缺失或目录不一致');
  }

  void extract(String name, File target, int expectedBytes, String cancelPath,
      {void Function(int bytes)? onProgress}) {
    final header = files[name];
    if (header == null || header.uncompressedSize != expectedBytes) {
      throw FormatException('备份缺少文件或体积不一致：$name');
    }
    input.setPosition(header.localHeaderOffset);
    final source = ZipFile(header)..read(input);
    if (source.filename != name || source.flags & 0x41 != 0 ||
        source.compressionMethod != (header.compressionMethod == 8 ? CompressionType.deflate : CompressionType.none) ||
        source.uncompressedSize != expectedBytes) {
      throw const FormatException('ZIP 本地文件头不一致');
    }
    target.parent.createSync(recursive: true);
    final output = _BoundedOutput(target.path, expectedBytes, cancelPath, onProgress);
    try {
      source.decompress(output);
      if (output.length != expectedBytes) throw const FormatException('解压后的文件体积不一致');
      onProgress?.call(output.length);
    } finally { output.closeSync(); }
  }

  void close() => input.closeSync();
}

/// 对实际写出字节限额，不能只信 ZIP 声明的解压大小。
class _BoundedOutput extends OutputFileStream {
  _BoundedOutput(String path, this.limit, this.cancelPath, this.onProgress)
    : super.withFileHandle(FileHandle(path, mode: FileAccess.write));
  final int limit;
  final String cancelPath;
  final void Function(int bytes)? onProgress;
  int _reported = 0;
  void _report() {
    // 解压器会逐字节调用写入；每 256 KiB 通知一次，避免淹没 UI 消息队列。
    if (onProgress != null && length - _reported >= 256 * 1024) {
      _reported = length;
      onProgress!(length);
    }
  }
  void _check(int count) {
    checkBackupWorker(cancelPath);
    if (length + count > limit) throw const FormatException('解压输出超过清单大小');
  }
  @override
  void writeByte(int value) { _check(1); super.writeByte(value); _report(); }
  @override
  void writeBytes(List<int> bytes, {int? length}) {
    _check(length ?? bytes.length); super.writeBytes(bytes, length: length); _report();
  }
}
