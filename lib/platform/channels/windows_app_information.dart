import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

/// 读取 Windows EXE 中 Runner 写入的版本资源。
Map<String, Object> windowsAppInformation(String path) => using((arena) {
  final executable = PCWSTR(path.toNativeUtf16(allocator: arena));
  final size = GetFileVersionInfoSize(executable, null).value;
  if (size == 0) throw FileSystemException('无法读取应用版本', path);
  final data = arena<Uint8>(size);
  final value = arena<Pointer<Void>>();
  final length = arena<Uint32>();
  if (!GetFileVersionInfo(executable, size, data).value ||
      !VerQueryValue(
        data,
        PCWSTR(r'\'.toNativeUtf16(allocator: arena)),
        value,
        length,
      ) ||
      length.value < sizeOf<VS_FIXEDFILEINFO>()) {
    throw FileSystemException('应用版本信息不完整', path);
  }
  final version = value.value.cast<VS_FIXEDFILEINFO>().ref;
  final major = version.dwFileVersionMS >> 16;
  final minor = version.dwFileVersionMS & 0xffff;
  final patch = version.dwFileVersionLS >> 16;
  return {
    'version': '$major.$minor.$patch',
    'build': version.dwFileVersionLS & 0xffff,
  };
});
