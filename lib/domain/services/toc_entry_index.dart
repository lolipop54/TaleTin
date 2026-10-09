/// 目录条目与阅读位置的计算（离线听书实现计划第 3、6.2 节）。
///
/// 纯计算：不读文件、不碰 Flutter 与 Riverpod，输入是目录树和已读到的章节列表。
/// 一个 XHTML 里可能装着上百章（目录的多个锚点指向同一个正文文件），
/// 所以索引一律按**目录条目**排，不按正文文件排。
///
/// 阅读器与听书共用这一套换算：听书的后台换章不能去问正在显示的页面，
/// 但可以复用这里的纯计算（实现计划第 3 节：先把可复用的纯计算小步移出）。
library;

import '../models/book_document.dart';

/// 目录条目在书里的位置：进度 + 章名 + 所属正文文件 + 原书锚点。
///
/// [anchorId] 是原书模式定位到章内某一条目用的锚点；没有锚点时
/// （例如整章就是一个条目）为 null。
typedef TocProgressEntry = ({
  double progress,
  String title,
  String chapterId,
  String? anchorId,
});

/// 目录标题在正文文件里的落点。
typedef TocTitleRef = ({String title, String? anchorId});

/// EPUB 正文常有“1.1.2 标题”，目录只写“标题”。精确匹配失败时才用此候选；
/// 不删除中文章号或标题内部数字，也不把“2026年”当作章节编号。
String tocHeadingWithoutNumber(String text) =>
    text.replaceFirst(RegExp(r'^\d+(?:\.\d+)*\s+'), '');

/// 判断「现在读到哪一条目录条目」时的进度容差。
///
/// 目录锚点常常挂在标题**前面**的容器上，落点位置比标题早一小段
/// （实测约 30 字，全书 26 万字即 1e-4）。
/// 按严格的 `<=` 比会被这点误差挤到上一条目。这只是容差上限；
/// 连续的父子标题可能只隔几个字，实际容差还要受相邻条目间距限制。
const double kTocProgressEpsilon = 5e-4;

/// 按正文文件 ID 汇总目录标题（深度优先，保持目录顺序）。
///
/// 相同目标只留第一条，同名但锚点不同的条目各自保留。
Map<String, List<TocTitleRef>> collectTocTitles(List<TocNode> toc) {
  final names = <String, List<TocTitleRef>>{};

  void visit(TocNode node) {
    final id = node.chapterId;
    final title = node.title.trim();
    if (id != null && title.isNotEmpty) {
      final titles = names.putIfAbsent(id, () => []);
      if (!titles.any((entry) => entry.anchorId == node.fragment)) {
        titles.add((title: title, anchorId: node.fragment));
      }
    }
    for (final child in node.children) {
      visit(child);
    }
  }

  for (final node in toc) {
    visit(node);
  }
  return names;
}

/// 按当前位置寻找目录条目。
///
/// 容差只用于同一个正文文件里的多个锚点；跨文件章首必须严格按 [chapterId]
/// 判断，否则短小的“版权信息”会被紧随其后的“目录”误认，下一章便会跳过目录。
/// [remembered] 仅由调用方在跳转落点尚未变化时传入，优先于页首位置。
int tocEntryIndexAt(
  List<TocProgressEntry> entries, {
  required double position,
  String? chapterId,
  int? remembered,
}) {
  var hit = -1;
  var firstInChapter = -1;
  for (var i = 0; i < entries.length; i++) {
    final entry = entries[i];
    if (chapterId != null && entry.chapterId != chapterId) continue;
    if (firstInChapter < 0) firstInChapter = i;
    // 父标题和子标题可能只隔几个字，容差不能跨过相邻条目间距的一半。
    final gap = i > 0 && entries[i - 1].chapterId == entry.chapterId
        ? entry.progress - entries[i - 1].progress : 0.0;
    final epsilon = chapterId == null ? 0.0
        : (gap / 2).clamp(0.0, kTocProgressEpsilon);
    if (entry.progress <= position + epsilon) hit = i;
  }
  if (hit < 0) hit = firstInChapter < 0 ? 0 : firstInChapter;
  if (remembered != null &&
      remembered >= 0 &&
      remembered < entries.length &&
      (chapterId == null || entries[remembered].chapterId == chapterId)) {
    hit = remembered;
  }
  return hit;
}
