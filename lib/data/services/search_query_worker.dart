import '../../domain/models/book_search.dart';
import '../../engine/search/search_chapter.dart';

final _probeWhitespace = RegExp(r'\s+');

/// 核对本章完整短语并映射原文位置，最多返回本批所需条数。
List<({BookSearchHit hit, int at})> matchSearchChapter(
  SearchChapter chapter,
  String title,
  String bookId,
  int version,
  String query,
  int offset,
  int limit,
) {
  final result = <({BookSearchHit hit, int at})>[];
  // 快速筛选只负责排除；查询也折叠空白，避免组合字符附着空格时误排除。
  if (!chapter.searchText.contains(query.replaceAll(_probeWhitespace, ' '))) {
    return result;
  }
  var from = offset;
  while (result.length < limit) {
    final at = chapter.normalized.text.indexOf(query, from);
    if (at < 0) break;
    result.add((
      hit: chapter.hit(bookId, version, title, at, query.length),
      at: at,
    ));
    from = at + 1;
  }
  return result;
}
