import 'locator.dart';

/// 搜索命中使用原正文位置；上下文中的强调区间为左闭右开。
class BookSearchHit {
  const BookSearchHit({
    required this.range,
    required this.chapterTitle,
    required this.context,
    required this.matchStart,
    required this.matchEnd,
  });
  final SelectionRange range;
  final String chapterTitle;
  final String context;
  final int matchStart;
  final int matchEnd;
  String get bookId => range.start.bookId;
  int get contentVersion => range.start.contentVersion;
}

/// 下一批从该章搜索文本的 offset 开始，不使用易变的页面号。
class BookSearchCursor {
  const BookSearchCursor(this.chapter, this.offset);
  final int chapter;
  final int offset;
}

class BookSearchPage {
  const BookSearchPage(this.hits, this.next);
  final List<BookSearchHit> hits;
  final BookSearchCursor? next;
}

/// 本批命中和真实搜索进度；未结束时不能把零命中说成全书无结果。
class BookSearchUpdate {
  const BookSearchUpdate(this.page, this.scanned, this.total, this.finished);
  final BookSearchPage page;
  final int scanned, total;
  final bool finished;
}

/// 前台查询与下一批预取分别持有取消令牌。
class SearchCancellation {
  bool cancelled = false;
  void cancel() => cancelled = true;
}

const bookSearchHelp =
    '按字面短语搜索；英文忽略大小写，连续空白视为一个空格。'
    '跨段查询用空格连接，不跨章搜索；图片文字不参与。';
