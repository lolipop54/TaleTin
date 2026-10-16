import 'dart:convert';
import 'dart:io';

import '../../core/io/source_fingerprint.dart';

/// 书架和两种正文读取器共享已完成的 SHA-256 核验，只复用同摘要、同文件状态。
/// 记录位于私有正文目录；备份恢复或外部改写导致状态变化时仍重新核验。
class SourceVerificationRecord {
  SourceVerificationRecord(String contentDirectory)
    : file = File('$contentDirectory/source.verified');
  final File file;

  bool matches(String digest, FileStat stat) {
    if (!file.existsSync()) return false;
    try {
      final value = jsonDecode(file.readAsStringSync());
      return value is Map &&
          value['digest'] == digest &&
          value['stamp'] == sourceFingerprint(stat);
    } on FormatException {
      return false; // 可重建记录写入中断时重新计算摘要。
    } on FileSystemException {
      return false; // 清理缓存或删除书籍与书架检查交错时，不依赖这份记录。
    }
  }

  void save(String digest, FileStat stat) {
    try {
      file.writeAsStringSync(
        jsonEncode({'digest': digest, 'stamp': sourceFingerprint(stat)}),
      );
    } on FileSystemException {
      // 核验已成功，磁盘满或目录刚被删除时只放弃这份可重建记录。
    }
  }
}
