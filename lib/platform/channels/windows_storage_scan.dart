import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;
import 'package:win32/win32.dart';

import '../../domain/repositories/storage_repository.dart';

WindowsProgramStorage readWindowsProgramStorage(String executablePath) {
  final executable = p.normalize(p.absolute(executablePath));
  final program = p.dirname(executable);
  final data = p.join(program, 'data');
  final assets = p.join(data, 'flutter_assets');
  final presets = p.join(assets, 'assets', 'fonts', 'preset');
  var directoryBytes = 0, bundledFontBytes = 0;
  scanWindowsStorage(
    program,
    (path, size) {
      if (p.isWithin(assets, path)) {
        directoryBytes += size;
        if (p.isWithin(presets, path) &&
            {
              '.ttf',
              '.otf',
              '.ttc',
            }.contains(p.extension(path).toLowerCase())) {
          bundledFontBytes += size;
        }
      } else if (p.equals(path, executable) ||
          p.equals(path, p.join(data, 'app.so')) ||
          p.equals(path, p.join(data, 'icudtl.dat')) ||
          p.equals(path, p.join(program, 'native_assets.json')) ||
          (p.equals(p.dirname(path), program) &&
              p.extension(path).toLowerCase() == '.dll')) {
        directoryBytes += size;
      }
    },
    // 解压目录也可能放着测试书库和其它文件，只进入 Flutter 的程序资源目录。
    descendInto: (path) =>
        p.equals(path, data) ||
        p.equals(path, assets) ||
        p.isWithin(assets, path),
  );
  return (directoryBytes: directoryBytes, bundledFontBytes: bundledFontBytes);
}

/// 枚举时同时读取文件名和长度。由后台 isolate 调用，不逐个打开文件。
void scanWindowsStorage(
  String root,
  void Function(String path, int size) file, {
  bool Function(String path)? descendInto,
}) {
  final directories = [p.normalize(p.absolute(root))];
  while (directories.isNotEmpty) {
    final directory = directories.removeLast();
    using((arena) {
      final entry = arena<WIN32_FIND_DATA>();
      final pattern = p.join(_longPath(directory), '*');
      final first = FindFirstFileEx(
        PCWSTR(pattern.toNativeUtf16(allocator: arena)),
        FindExInfoBasic,
        entry.cast(),
        FindExSearchNameMatch,
        FIND_FIRST_EX_LARGE_FETCH,
      );
      if (first.value == INVALID_HANDLE_VALUE) {
        // 空目录或扫描期间被清除的缓存没有可以统计的条目。
        if (first.error == ERROR_FILE_NOT_FOUND ||
            first.error == ERROR_PATH_NOT_FOUND) {
          return;
        }
        throw _scanError(directory, first.error);
      }
      try {
        while (true) {
          final data = entry.ref;
          final name = data.cFileName;
          final attributes = data.dwFileAttributes;
          // 书库目录里面的链接和目录联接不属于应用管理的文件。
          if (name != '.' &&
              name != '..' &&
              attributes & FILE_ATTRIBUTE_REPARSE_POINT == 0) {
            final path = p.join(directory, name);
            if (attributes & FILE_ATTRIBUTE_DIRECTORY != 0) {
              if (descendInto?.call(path) ?? true) directories.add(path);
            } else {
              file(path, (data.nFileSizeHigh << 32) | data.nFileSizeLow);
            }
          }
          final next = FindNextFile(first.value, entry);
          if (!next.value) {
            if (next.error == ERROR_NO_MORE_FILES) break;
            throw _scanError(directory, next.error);
          }
        }
      } finally {
        FindClose(first.value);
      }
    });
  }
}

String _longPath(String path) {
  if (path.startsWith(r'\\?\')) return path;
  if (path.startsWith(r'\\')) return r'\\?\UNC\' + path.substring(2);
  return r'\\?\' + path;
}

FileSystemException _scanError(String path, WIN32_ERROR error) =>
    FileSystemException('读取存储目录失败', path, OSError('', error));
