import 'dart:io';
import 'package:path/path.dart' as p;

/// 新书仅保存路径记录；没有原路径的旧书继续使用原有私有副本。
String bookSourcePath(String directory, String extension) {
  final reference = File(p.join(directory, 'source.path'));
  return reference.existsSync()
      ? reference.readAsStringSync()
      : p.join(directory, 'source.$extension');
}
