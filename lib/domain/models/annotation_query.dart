import 'annotation.dart';
import 'book.dart';

/// 日期筛选以创建时间为准，until 不包含在范围内；界面将本地日期转 UTC。
class AnnotationQuery {
  const AnnotationQuery({
    this.keyword = '',
    this.bookId,
    this.from,
    this.until,
    this.limit = 50,
  });
  final String keyword;
  final String? bookId;
  final DateTime? from;
  final DateTime? until;
  final int limit;

  @override
  bool operator ==(Object other) =>
      other is AnnotationQuery &&
      keyword == other.keyword &&
      bookId == other.bookId &&
      from == other.from &&
      until == other.until &&
      limit == other.limit;
  @override
  int get hashCode => Object.hash(keyword, bookId, from, until, limit);
}

/// 书名来自保留的书籍行；删除书籍后仍能显示和筛选笔记。
class AnnotatedBook {
  const AnnotatedBook(this.id, this.title, this.status);
  final String id;
  final String title;
  final BookStatus status;
}

class BookAnnotation {
  const BookAnnotation(this.book, this.annotation);
  final AnnotatedBook book;
  final Annotation annotation;
}

class AnnotationPage {
  const AnnotationPage(this.items, this.hasMore);
  final List<BookAnnotation> items;
  final bool hasMore;
}
