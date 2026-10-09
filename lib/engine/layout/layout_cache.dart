/// 分页结果的内存缓存（实现计划 S6）。
///
/// 键里含内容版本、章节、字体、字号/行高/段距/缩进/页边距、内容区尺寸、
/// TextScaler 与引擎版本，因此任何一项变化都会自然换键、不会读到旧排版；
/// 颜色主题不在键里——换主题只重绘，不重排（设计文档 6.4）。
///
/// 本轮只放内存；实测再次打开超过 800ms 再考虑落盘缓存。
library;

import 'chapter_layout.dart';

class LayoutCache {
  LayoutCache({this.capacity = 3});

  /// 缓存的章节数：阅读器实际只用到当前章与相邻章
  final int capacity;

  final _entries = <String, ChapterLayout>{};

  static String keyFor({
    required String bookId,
    required int contentVersion,
    required String chapterId,
    required String layoutSignature,
  }) =>
      '$bookId|$contentVersion|$chapterId|$layoutSignature';

  ChapterLayout? get(String key) {
    final hit = _entries.remove(key);
    if (hit != null) {
      // 命中后移到队尾，淘汰的是最久未用的那一章
      _entries[key] = hit;
    }
    return hit;
  }

  void put(String key, ChapterLayout layout) {
    _entries.remove(key);
    _entries[key] = layout;
    while (_entries.length > capacity) {
      _entries.remove(_entries.keys.first);
    }
  }

  /// 参数变化（如改字号）后按书的维度丢弃：键里已经有签名，这里只是省内存
  void invalidate({String? bookId}) {
    if (bookId == null) {
      _entries.clear();
      return;
    }
    _entries.removeWhere((key, _) => key.startsWith('$bookId|'));
  }

  int get length => _entries.length;
}
