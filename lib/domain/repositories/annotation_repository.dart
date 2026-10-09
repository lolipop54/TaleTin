/// 标注仓库（设计文档 7.1 annotations 表 / 第 222 行的 AnnotationRepository）。
///
/// 书签、高亮、笔记共用一张表（`kind` 区分），接口按用途分开：
/// 书签只记一个位置，高亮与笔记是一段选文加摘录，两者都可能带想法文字。
library;

import '../models/annotation.dart';
import '../models/annotation_query.dart';
import '../models/bookmark.dart';
import '../models/locator.dart';

abstract interface class AnnotationRepository {
  /// 跨书查询只取当前批次，并多读一条判断是否还有下一批。
  Stream<AnnotationPage> watchAnnotationPage(AnnotationQuery query);
  Stream<List<AnnotatedBook>> watchAnnotatedBooks();
  Stream<int> watchAnnotationCount();
  /// 一本书的书签，最近加的在前
  Stream<List<Bookmark>> watchBookmarks(String bookId);

  /// 在 [locator] 处加书签（同一位置重复添加只保留一个），返回书签 id
  Future<String> addBookmark({required Locator locator, required String quote});

  Future<void> removeBookmark(String id);

  /// 一本书的高亮与笔记（不含书签），最近改动的在前。
  ///
  /// 顺序在列表侧还要按正文顺序重排，这里给的是稳定次序：
  /// 先按最后修改时间，保证「刚写的那条」在最上面。
  Stream<List<Annotation>> watchAnnotations(String bookId);

  /// 找出落在这段选文上的标注（两端顺序无所谓），没有则返回 null。
  ///
  /// 用于「同一选区再次操作就是改那一条」：先问有没有，再决定是编辑还是新建。
  /// 重复与否只看位置，不看摘录文字——同一段文字在书里可能出现很多次。
  Future<Annotation?> findByRange(String bookId, SelectionRange range);

  /// 保存一条高亮或笔记，返回记录 id。
  ///
  /// - 带 [id] 是修改已有记录（高亮写想法 → 笔记，或改颜色、改想法）；
  /// - 不带 [id] 时先按选区找：同一选区已有记录就改它，不会多出一条；
  /// - 都不满足才新建。
  ///
  /// [range] 两端顺序由调用方保证按阅读顺序（N3 规范化）；
  /// [quote] 是完整选文，不是 Locator 里那 32 个字的定位摘录；
  /// [chapterTitle] 是章节标题快照，书移除后列表还要靠它显示位置。
  /// 修改时间由仓库维护，调用方不用管。
  Future<String> saveAnnotation({
    String? id,
    required String bookId,
    required AnnotationKind kind,
    required SelectionRange range,
    required String quote,
    String body = '',
    AnnotationColor? color,
    String chapterTitle = '',
  });

  /// 删除一条高亮或笔记（书签用 [removeBookmark]）
  Future<void> deleteAnnotation(String id);
}
