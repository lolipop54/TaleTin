/// 导入所需的文件系统能力契约。
///
/// 运行时目录结构（设计文档第 5 节）：
/// - `library/<bookId>/source.<ext>` 用户文件的持久副本
/// - `library/<bookId>/content/<版本>/` 标准化章节与资源
/// - `cache/import/<jobId>/` 导入暂存目录，提交或失败后清理
library;

import '../models/book_document.dart';

/// 一次分块复制的结果。
class CopiedFile {
  const CopiedFile({required this.byteCount, required this.sha256Hex});

  final int byteCount;

  /// 原始文件 SHA-256（十六进制小写），用于去重
  final String sha256Hex;
}

class StorageDeletion {
  const StorageDeletion({required this.freedBytes, required this.failed});
  final int freedBytes;
  final bool failed;
}

abstract class ImportStorage {
  /// 书籍目录绝对路径（不存在时创建）。
  Future<String> bookDirectory(String bookId);

  /// 导入暂存目录绝对路径（不存在时创建）。
  Future<String> stagingDirectory(String jobId);

  Future<void> ensureDirectory(String path);

  /// 把分块读取器写入目标文件，边写边计算 SHA-256。
  ///
  /// [readChunk] 返回 null 表示数据结束；[isCancelled] 返回 true 时中止
  /// 复制并抛 [ImportFailure]（cancelled）。
  Future<CopiedFile> copyStream({
    required String targetPath,
    required Future<List<int>?> Function() readChunk,
    required void Function(int copiedBytes) onProgress,
    required bool Function() isCancelled,
  });

  Future<void> writeBytes(String path, List<int> bytes);

  /// 原子移动目录/文件。目标所在卷与源相同，避免跨卷非原子复制。
  Future<void> move({required String from, required String to});

  Future<void> deleteRecursively(String path);

  /// 一遍遍历中统计并删除，只累计确认删除成功的文件；不使用确认前的旧估计。
  Future<StorageDeletion> deleteRecursivelyWithSize(String path);

  /// 清理不属于 [keepJobIds] 的暂存目录，返回清掉的目录数。
  Future<int> cleanupStaging({required Iterable<String> keepJobIds});

  /// 目录占用的字节数（含子目录），用于删除前告知影响。
  ///
  /// 目录不存在时返回 0；无法读取的文件按 0 计，不因为统计失败阻断删除。
  Future<int> directorySize(String path);

  /// 书籍目录的绝对路径（不创建目录）。
  Future<String> bookDirectoryPath(String bookId);

  /// 启动时回收完整 TXT 书籍中不再使用的全文转码副本，返回实际释放字节。
  /// 章节或清单不完整时保留副本，不修改正文、源书或位置记录。
  Future<int> removeRedundantTxtCopy(
    String bookId,
    int contentVersion,
    List<Chapter> chapters,
  );
}
