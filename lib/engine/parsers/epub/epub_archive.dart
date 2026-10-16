/// EPUB 容器访问：ZIP 打开、条目定位与安全防护。
///
/// 防护口径（设计文档 6.1「阈值双重校验」）：
/// - 条目数在解压前检查；
/// - 单条目与总输出做「声明值预检 + 实际输出累计」双重校验；
/// - 条目路径统一规范化，越出根目录的路径（路径穿越）直接拒绝；
/// - 条目按需解压，用完立即释放，不同时把整本书的解压内容留在内存里。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:direct_read_rust/direct_read_rust.dart';

import '../../../core/errors/import_error.dart';
import '../../../core/diagnostics/import_timing.dart';
import '../../normalization/text_decoding.dart';

class EpubArchive {
  EpubArchive._(this._archive, this._input);

  final Archive _archive;
  final InputFileStream _input;
  ImportTiming? importTiming;
  NativeInflater? _inflater;

  /// 条目数上限
  static const int maxEntries = 20000;

  /// 单条目解压后上限
  static const int maxEntryBytes = 50 * 1024 * 1024;

  /// 整本解压输出上限
  static const int maxTotalBytes = 1024 * 1024 * 1024;

  int _totalWritten = 0;
  int get decodedBytes => _totalWritten;

  /// 打开 ZIP。非 ZIP 内容会在这里抛出 `invalidContainer`。
  static EpubArchive open(String path) {
    final input = InputFileStream(path);
    final Archive archive;
    try {
      archive = ZipDecoder().decodeStream(input);
    } catch (error) {
      input.closeSync();
      throw ImportFailure(ImportErrorCode.invalidContainer, 'ZIP 解析失败');
    }
    if (archive.files.length > maxEntries) {
      input.closeSync();
      throw const ImportFailure(ImportErrorCode.unsafeArchive, '文件条目过多');
    }
    return EpubArchive._(archive, input);
  }

  int get entryCount => _archive.files.length;

  /// 按规范化后的归档内路径查找条目。
  ArchiveFile? find(String entryPath) {
    final normalized = normalizeEntryPath(entryPath);
    if (normalized == null) return null;
    final entry = _archive.find(normalized);
    if (entry == null || entry.isDirectory) return null;
    return entry;
  }

  bool contains(String entryPath) => find(entryPath) != null;

  /// 读取条目内容；[limit] 用于只读文件头的情况。
  Uint8List readBytes(String entryPath, {int? limit}) =>
      importTiming?.detail(
        'zip_entry_read_inflate',
        () => _readBytes(entryPath, limit: limit),
      ) ??
      _readBytes(entryPath, limit: limit);

  Uint8List _readBytes(String entryPath, {int? limit}) {
    final entry = find(entryPath);
    if (entry == null) {
      throw ImportFailure(ImportErrorCode.invalidContainer, '缺少 $entryPath');
    }
    _checkDeclaredSize(entry, entryPath);
    // 保留指向 ZIP 原文件的压缩条目，只返回本次解压的字节。
    // 不把解压结果挂在 ArchiveFile 上，也不 clear 掉再次读取所需的信息。
    final raw = entry.rawContent;
    Uint8List? bytes;
    // Keep archive's ZIP indexing and encryption handling. Only replace raw
    // DEFLATE expansion; stored/BZip2 entries keep their existing behavior.
    if (ProcessingFeatures.nativeInflate &&
        raw is ZipFile &&
        raw.compressionMethod == CompressionType.deflate) {
      final compressed = raw.getStream(decompress: false);
      final position = compressed.position;
      try {
        _inflater ??= NativeInflater();
        bytes = _inflater!.decode(compressed.toUint8List(), maxEntryBytes);
      } on NativeInflateLimit {
        throw const ImportFailure(ImportErrorCode.unsafeArchive, '单条资源过大');
      } on FormatException {
        throw const ImportFailure(ImportErrorCode.invalidContainer, '条目无法解压');
      } finally {
        compressed.setPosition(position);
      }
    } else {
      bytes = raw?.getStream().toUint8List();
    }
    if (bytes == null) {
      throw ImportFailure(ImportErrorCode.invalidContainer, '条目无法解压');
    }
    if (bytes.length > maxEntryBytes) {
      throw ImportFailure(ImportErrorCode.unsafeArchive, '单条资源过大');
    }
    _totalWritten += bytes.length;
    if (_totalWritten > maxTotalBytes) {
      throw const ImportFailure(ImportErrorCode.unsafeArchive, '解压内容超出上限');
    }
    if (limit != null && bytes.length > limit) {
      return Uint8List.sublistView(bytes, 0, limit);
    }
    return bytes;
  }

  /// 读取文本条目：按 BOM / UTF-8 解码（EPUB 内部文档通常是 UTF-8）。
  String readText(String entryPath) {
    final bytes = readBytes(entryPath);
    return importTiming?.detail(
          'text_decode_transfer',
          () => decodeTextBytes(bytes),
        ) ??
        decodeTextBytes(bytes);
  }

  /// 把资源条目写到目标文件。目标已存在时跳过，避免同一图片重复写盘。
  ///
  /// 返回目标文件是否已存在（已跳过）。
  bool extractTo(String entryPath, String targetPath, {int? limit}) {
    final entry = find(entryPath);
    if (entry == null) {
      throw ImportFailure(ImportErrorCode.invalidContainer, '缺少 $entryPath');
    }
    final file = File(targetPath);
    if (file.existsSync()) return true;
    final bytes = readBytes(entryPath);
    if (limit != null && bytes.length > limit) {
      throw ImportFailure(ImportErrorCode.unsafeArchive, '单条资源过大');
    }
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(bytes, flush: false);
    return true;
  }

  void close() {
    _inflater?.close();
    for (final file in _archive.files) {
      file.clear();
    }
    _input.closeSync();
  }

  /// 清零解压总量累计。
  ///
  /// 总输出上限（[maxTotalBytes]）是防解压炸弹用的。原书排版模式会长期持有
  /// 同一个归档并反复读同一批资源，累计值迟早触顶；换章时重置一次，预算按
  /// 「一章 + 它的资源」计算，仍远低于上限，防护不失效。
  void resetTotalBudget() => _totalWritten = 0;

  /// 声明值预检：压缩包可能在头部伪造极小的解压尺寸。
  void _checkDeclaredSize(ArchiveFile entry, String entryPath) {
    if (entry.size > maxEntryBytes) {
      throw ImportFailure(ImportErrorCode.unsafeArchive, '单条内容声明过大：$entryPath');
    }
  }
}

/// 归档内路径规范化。
///
/// 统一分隔符、去掉 `./`、合并 `..`；越出根目录或绝对路径返回 null
/// （设计文档 6.1：阻止 ZIP 路径穿越）。
String? normalizeEntryPath(String path) {
  var value = path.replaceAll('\\', '/').trim();
  if (value.isEmpty) return null;
  if (value.startsWith('/')) return null;
  // 去掉查询与片段，EPUB 内部引用可能带 #fragment
  final hash = value.indexOf('#');
  if (hash >= 0) value = value.substring(0, hash);
  final query = value.indexOf('?');
  if (query >= 0) value = value.substring(0, query);
  if (value.isEmpty) return null;
  final normalized = p.posix.normalize(value);
  if (normalized == '..' || normalized.startsWith('../')) return null;
  return normalized;
}

/// 以归档内某个文件为基准解析相对引用，返回规范化路径。
String? resolveEntryPath(String baseFile, String href) {
  // EPUB 常直接写中文路径或 #中文锚点；decodeFull 只接受 ASCII URI。
  // 先由 Uri 编码原始中文，再解码，兼容中文与已有 % 编码混写的链接。
  final uri = Uri.parse(href.replaceAll('\\', '/'));
  // 内嵌脚注图和外部 URL 不属于 ZIP 条目；导入与位置对照必须一起跳过。
  if (uri.hasScheme || uri.hasAuthority) return null;
  final decoded = Uri.decodeFull(uri.toString());
  if (decoded.startsWith('/')) return normalizeEntryPath(decoded.substring(1));
  final dir = p.posix.dirname(baseFile);
  return normalizeEntryPath(dir == '.' ? decoded : p.posix.join(dir, decoded));
}
