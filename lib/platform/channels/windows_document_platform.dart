import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:direct_read_rust/direct_read_rust.dart';
import 'package:ffi/ffi.dart';
import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:file_selector_windows/file_selector_windows.dart';
import 'package:path/path.dart' as p;
import 'package:win32/win32.dart';

import '../../domain/models/book.dart';
import '../../domain/services/document_platform.dart';

PickedDocument _documentFromPath(String path) => PickedDocument(
  uri: Uri.file(path, windows: true).toString(),
  name: p.windows.basename(path),
);

/// 只把可用的书籍文件交给同一条导入队列，混合拖放时保留批次里的其他书。
Future<List<PickedDocument>> windowsDroppedBooks(List<String> paths) async {
  final documents = await Future.wait(
    paths.map((path) async {
      final extension = p.windows.extension(path);
      if (extension.isEmpty ||
          BookFormat.fromCode(extension.substring(1).toLowerCase()) == null) {
        return null;
      }
      try {
        return await FileSystemEntity.type(path) == FileSystemEntityType.file
            ? _documentFromPath(path)
            : null;
      } on FileSystemException {
        return null;
      }
    }),
  );
  return documents.whereType<PickedDocument>().toList();
}

class WindowsDocumentPlatform implements DocumentPlatform {
  WindowsDocumentPlatform({FileSelectorPlatform? picker})
    : _picker = picker ?? FileSelectorWindows();

  final FileSelectorPlatform _picker;
  final _files = <int, RandomAccessFile>{};
  int _nextId = 0;

  Future<List<String>> pickFontPaths() async {
    final files = await _picker.openFiles(
      acceptedTypeGroups: const [
        XTypeGroup(label: '字体文件', extensions: ['ttf', 'otf', 'ttc']),
      ],
    );
    return [for (final file in files) file.path];
  }

  @override
  Future<List<PickedDocument>> pickDocuments() async {
    final files = await _picker.openFiles(
      acceptedTypeGroups: [
        XTypeGroup(
          label: '书籍',
          extensions: [for (final format in BookFormat.values) format.code],
        ),
      ],
    );
    // 文件属性仍由导入流程确认。批量选择里一个文件消失，不应丢掉其余文件。
    return [for (final file in files) _documentFromPath(file.path)];
  }

  @override
  Future<DocumentSession> open(String uri) async {
    final file = await File.fromUri(Uri.parse(uri)).open();
    try {
      final size = await file.length();
      final id = ++_nextId;
      _files[id] = file;
      return DocumentSession(id: id, sizeBytes: size);
    } catch (_) {
      await file.close();
      rethrow;
    }
  }

  @override
  Future<Uint8List?> readChunk(DocumentSession session, int maxBytes) async {
    final file = _files[session.id];
    if (file == null) throw StateError('文件读取已结束');
    final bytes = await file.read(maxBytes.clamp(1, 1024 * 1024));
    return bytes.isEmpty ? null : bytes;
  }

  @override
  Future<void> close(DocumentSession session) async {
    await _files.remove(session.id)?.close();
  }

  @override
  Future<String> decodeBytes(Uint8List bytes, String charsetName) async =>
      decodeNativeText(bytes, charsetName);

  @override
  Future<String> transcodeToUtf8({
    required String sourcePath,
    required String charsetName,
    required String targetPath,
  }) async {
    await transcodeNativeFile(sourcePath, targetPath, charsetName);
    return charsetName;
  }

  @override
  Future<int> availableBytes(String path) async => using((arena) {
    final available = arena<Uint64>();
    final result = GetDiskFreeSpaceEx(
      PCWSTR(p.absolute(path).toNativeUtf16(allocator: arena)),
      available,
      null,
      null,
    );
    if (!result.value) throw FileSystemException('无法查询磁盘可用空间', path);
    return available.value;
  });

  @override
  Future<List<String>> supportedCharsets() async => nativeCharsets;
}
