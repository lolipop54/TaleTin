import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../domain/models/locator.dart';
import 'reader_session_view_model.dart';

/// 当前真正上屏的两页，供共用书签和听书判断；不写入数据库，也不保存邻页为阅读点。
final visibleSpreadProvider = NotifierProvider.autoDispose
    .family<VisibleSpread, List<SpreadPageRef>, String>(VisibleSpread.new);

class VisibleSpread extends Notifier<List<SpreadPageRef>> {
  VisibleSpread(this.bookId);
  final String bookId;
  @override
  List<SpreadPageRef> build() => const [];
  void show(List<SpreadPageRef> pages) => state = pages;
}

/// 异步换章期间旧双页继续显示，跟读和大图返回只认本次会话的双页。
bool spreadShowsSession(List<SpreadPageRef> pages, ReaderSession session) =>
    pages.any(
      (p) =>
          p.layout.samePageAs(session.layout, p.pageIndex, session.pageIndex),
    );

bool spreadContains(List<SpreadPageRef> pages, Locator point) => pages.any(
  (p) =>
      p.layout.chapterId == point.chapterId &&
      p.layout.pageIndexOf(point) == p.pageIndex,
);
