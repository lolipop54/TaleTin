import 'dart:io';

import 'package:path/path.dart' as p;

/// 测试包和便携包把书库、缓存和诊断日志保存在程序旁边。
Directory? get windowsSideBySideStorageRoot {
  if (!Platform.isWindows) return null;
  final executableDirectory = p.dirname(Platform.resolvedExecutable);
  const isolated = bool.fromEnvironment('GT_WINDOWS_ISOLATED_TEST_LIBRARY');
  if (isolated) {
    return Directory(p.join(executableDirectory, 'TaleTin-test-library'));
  }
  final marker = File(p.join(executableDirectory, 'TaleTin.portable'));
  if (!marker.existsSync()) return null;
  return Directory(p.join(executableDirectory, 'TaleTin-data'));
}

String? get windowsAppStorageRoot {
  if (!Platform.isWindows) return null;
  final sideBySide = windowsSideBySideStorageRoot;
  if (sideBySide != null) return sideBySide.path;
  final localData = Platform.environment['LOCALAPPDATA'];
  return localData == null || localData.isEmpty
      ? null
      : p.join(localData, 'TaleTin');
}
