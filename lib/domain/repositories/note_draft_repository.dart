/// 笔记草稿仓库（实现计划 N4）。
///
/// 草稿按书保存，一本书一份；它不是缓存，清缓存不删它，
/// 保存成功或用户明确放弃时由调用方删掉。
library;

import '../models/note_draft.dart';

abstract interface class NoteDraftRepository {
  /// 这本书的草稿；没有或已清掉时返回 null
  Future<NoteDraft?> load(String bookId);

  /// 覆盖式写入草稿
  Future<void> save(String bookId, NoteDraft draft);

  /// 删除草稿（保存成功、放弃修改、笔记不存在时都用它）
  Future<void> clear(String bookId);
}
