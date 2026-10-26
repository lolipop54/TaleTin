import 'package:flutter/painting.dart';

import 'page_canvas.dart';
import 'prepared_page.dart';

/// 只保留当前阅读窗口的已解码图片。动画取得独立引用，落页或淘汰不会释放在途图片。
class PreparedPageCache {
  PreparedPageCache({this.budgetBytes = 48 * 1024 * 1024});

  final int budgetBytes;
  final _pages = <Object, PreparedPage>{};
  final _pending = <Object, Future<void>>{};
  Set<Object> _wanted = {};
  bool _disposed = false;

  Object _key(PageCanvas page, ImageConfiguration configuration) => (
    page.layout.bookId,
    page.layout.contentVersion,
    page.layout.page(page.pageIndex),
    configuration,
  );

  int get bytes => _pages.values.fold(0, (sum, page) => sum + page.imageBytes);

  void retain(List<PageCanvas> pages, ImageConfiguration configuration) {
    _wanted = {for (final page in pages) _key(page, configuration)};
    for (final key in _pages.keys.toList()) {
      if (!_wanted.contains(key)) _pages.remove(key)!.dispose();
    }
  }

  /// 静态页借出材料，由缓存复制引用；不再从磁盘重新解码当前页。
  void remember(PreparedPage page, ImageConfiguration configuration) {
    if (_disposed || page.hasFailedImages) return;
    final key = _key(page.page, configuration);
    if (!_wanted.contains(key)) return;
    final previous = _pages[key];
    if (previous != null && previous.sameImagesAs(page)) return;
    _pages.remove(key)?.dispose();
    _pages[key] = page.clone();
    // 三个阅读页通常远小于预算；极端图文页按实际解码字节淘汰，不能无界保留。
    while (bytes > budgetBytes && _pages.isNotEmpty) {
      _pages.remove(_pages.keys.first)!.dispose();
    }
  }

  bool contains(PageCanvas page, ImageConfiguration configuration) =>
      !_disposed && _pages.containsKey(_key(page, configuration));

  PreparedPage? find(PageCanvas page, ImageConfiguration configuration) {
    final key = _key(page, configuration);
    final ready = _pages.remove(key);
    if (ready == null) return null;
    _pages[key] = ready;
    // 内容相同，信息行、书签、选区和主题取本轮画面，避免沿用预取时的旧外观。
    return ready.cloneFor(page);
  }

  Future<void> prepare(PageCanvas page, ImageConfiguration configuration) {
    final key = _key(page, configuration);
    if (_disposed || contains(page, configuration)) return Future.value();
    return _pending.putIfAbsent(key, () => _load(page, configuration, key));
  }

  Future<void> _load(
    PageCanvas page,
    ImageConfiguration configuration,
    Object key,
  ) async {
    try {
      final prepared = await PreparedPage.load(page, configuration);
      try {
        remember(prepared, configuration);
      } finally {
        prepared.dispose();
      }
    } finally {
      _pending.remove(key);
    }
  }

  void dispose() {
    _disposed = true;
    _wanted = {};
    for (final page in _pages.values) {
      page.dispose();
    }
    _pages.clear();
  }
}
