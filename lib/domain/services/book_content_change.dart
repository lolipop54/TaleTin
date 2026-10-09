/// 正文变更前停止自动阅读、听书和搜索，等待保存/读取收尾；必须在 finally 释放。
typedef PrepareBookContentChange = Future<void Function()> Function(
  String bookId,
);
