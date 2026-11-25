import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:file_selector_windows/file_selector_windows.dart';
import 'package:path/path.dart' as p;

import 'backup_documents.dart';

class WindowsBackupDocuments extends BackupDocuments {
  WindowsBackupDocuments({FileSelectorPlatform? picker})
    : _picker = picker ?? FileSelectorWindows();

  static const _images = [
    XTypeGroup(
      label: '图片',
      extensions: ['png', 'jpg', 'jpeg', 'webp', 'bmp', 'gif'],
    ),
  ];

  final FileSelectorPlatform _picker;
  RandomAccessFile? _output;
  File? _temporary;
  File? _destination;

  @override
  Future<String?> pick() async {
    final file = await _picker.openFile(
      acceptedTypeGroups: const [
        XTypeGroup(label: '书库备份', extensions: ['zip']),
      ],
    );
    return file == null ? null : Uri.file(file.path).toString();
  }

  @override
  Future<String?> pickImage() async {
    final file = await _picker.openFile(acceptedTypeGroups: _images);
    return file == null ? null : Uri.file(file.path).toString();
  }

  @override
  Future<List<String>> pickImages(int limit) async {
    final files = await _picker.openFiles(acceptedTypeGroups: _images);
    return [
      for (final file in files.take(limit)) Uri.file(file.path).toString(),
    ];
  }

  @override
  Future<List<String>> pickCoverImages(int limit) async {
    final files = await _picker.openFiles(acceptedTypeGroups: _images);
    // 封面页需要收到完整批次，超出上限时才能提示用户重新选择。
    return [for (final file in files) Uri.file(file.path).toString()];
  }

  @override
  Future<String?> create(String name, String mime) async {
    final extension = p.extension(name);
    final selection = await _picker.getSaveLocation(
      options: SaveDialogOptions(suggestedName: name),
      acceptedTypeGroups: extension.isEmpty
          ? null
          : [
              XTypeGroup(
                label: extension.substring(1),
                extensions: [extension.substring(1)],
              ),
            ],
    );
    return selection == null ? null : Uri.file(selection.path).toString();
  }

  @override
  Future<void> open(String uri) async {
    if (_destination != null) throw StateError('正在写入另一个文件');
    final destination = File.fromUri(Uri.parse(uri));
    // 在同一目录写临时文件。取消导出时保留用户已存在的目标文件。
    final staging = await destination.parent.createTemp('.taletin-');
    _destination = destination;
    final temporary = _temporary = File(p.join(staging.path, 'output'));
    _output = await temporary.open(mode: FileMode.write);
  }

  @override
  Future<void> write(Uint8List bytes) async {
    await _output!.writeFrom(bytes);
  }

  @override
  Future<void> finish() async {
    await _output!.flush();
    await _close();
    final temporary = _temporary!;
    await temporary.rename(_destination!.path);
    _temporary = null;
    _destination = null;
    // 发布已完成，空临时目录清理失败不应把成功保存记成失败。
    try {
      await temporary.parent.delete();
    } on FileSystemException {
      // 目录可能被资源管理器短暂占用。
    }
  }

  @override
  Future<bool> abort(String uri) async {
    if (_destination?.uri != Uri.parse(uri)) return true;
    try {
      await _close();
      final temporary = _temporary!;
      if (await temporary.exists()) await temporary.delete();
      await temporary.parent.delete();
      return true;
    } on FileSystemException {
      return false;
    } finally {
      _temporary = null;
      _destination = null;
    }
  }

  Future<void> _close() async {
    final output = _output;
    _output = null;
    await output?.close();
  }
}
