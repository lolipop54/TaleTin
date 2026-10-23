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

bool spreadContains(List<SpreadPageRef> pages, Locator point) => pages.any(
  (p) =>
      p.layout.chapterId == point.chapterId &&
      p.layout.pageIndexOf(point) == p.pageIndex,
);
