import '../../../../domain/models/book_search.dart';

class BookSearchState {
  const BookSearchState({
    this.query = '',
    this.resultQuery = '',
    this.hits = const [],
    this.next,
    this.busy = false,
    this.error,
    this.complete = false,
    this.cancelled = false,
    this.scanned = 0,
    this.total = 0,
  });
  final String query;

  /// 保留旧列表时标明它属于哪次查询，不把旧结果冒充新词结果。
  final String resultQuery;
  final List<BookSearchHit> hits;
  final BookSearchCursor? next;
  final bool busy;
  final String? error;
  final bool complete;
  final bool cancelled;
  final int scanned, total;
  BookSearchState copyWith({
    String? query,
    String? resultQuery,
    List<BookSearchHit>? hits,
    BookSearchCursor? next,
    bool clearNext = false,
    bool? busy,
    String? error,
    bool clearError = false,
    bool? complete,
    bool? cancelled,
    int? scanned,
    int? total,
  }) => BookSearchState(
    query: query ?? this.query,
    resultQuery: resultQuery ?? this.resultQuery,
    hits: hits ?? this.hits,
    next: clearNext ? null : next ?? this.next,
    busy: busy ?? this.busy,
    error: clearError ? null : error ?? this.error,
    complete: complete ?? this.complete,
    cancelled: cancelled ?? this.cancelled,
    scanned: scanned ?? this.scanned,
    total: total ?? this.total,
  );
}
