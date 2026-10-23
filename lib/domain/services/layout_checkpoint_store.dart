import '../models/book_document.dart';

/// 可重建排版资料，与正文、书签和阅读位置分开保存。
abstract interface class LayoutCheckpointStore {
  Future<String?> identity({
    required String bookId,
    required String title,
    required ChapterContent content,
    required String layout,
    required String? fontFamily,
  });

  /// 只读取覆盖目标游标的分段；已有的测量行不重复解压、传回主线程。
  /// throughCursor 为空时读取剩余全部，供章末和完整结果请求使用。
  Future<Map<String, dynamic>?> read(
    String bookId,
    String identity, {
    int? throughCursor,
    int afterBlocks = 0,
  });
  Future<void> write(
    String bookId,
    String identity,
    Map<String, Object?> checkpoint,
  );

  /// 调用方先作废生产者；等待已接受写入收尾后再删除可重建文件。
  Future<void> clear([String? bookId]);
}
