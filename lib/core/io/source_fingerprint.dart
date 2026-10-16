import 'dart:io';

/// 摘要核验绑定到这一次实际文件状态，等长替换也会使指纹失效。
String sourceFingerprint(FileStat stat) =>
    '${stat.size}:${stat.modified.microsecondsSinceEpoch}:${stat.changed.microsecondsSinceEpoch}';
