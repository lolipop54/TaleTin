/// 选区规范化与摘录提取（实现计划 N3）。
///
/// 界面上拖出来的两个 Locator 可能是反的、偏移可能落在字素簇中间，
/// 摘录必须是完整选文而不是 Locator 里那 32 个字的定位短摘录。
/// 这几条规则集中在这里，界面、保存流程和测试共用一份实现。
///
/// **顺序口径**：章节序号（`chapters.ordinal`）→ 块序号（`b12` 的数字部分，
/// 解析器按文档顺序编号）→ 块内 UTF-16 偏移 → 定位倾向。
/// 章节 ID 与块 ID 是生成的字符串，不能拿它们的字典序当阅读顺序。
library;


import '../../domain/models/book_document.dart';
import '../../domain/models/locator.dart';
import '../normalization/locator_mapper.dart';

/// 章节序号未知时的兜底值：排在所有已知章节之后。
///
/// 正常流程里选区的两端都来自当前书已加载的章节，不会走到这里；
/// 兜底是为了不因为一条过期位置把阅读页弄崩。
const int kUnknownChapterOrdinal = 1 << 30;

/// 章节顺序表（章节 ID → 阅读序号），取自 `chapters` 表的 ordinal。
Map<String, int> chapterOrdinalsOf(List<Chapter> chapters) => {
      for (final chapter in chapters) chapter.id: chapter.ordinal,
    };

/// 章内块序号：`b12` → 12。解析器按文档顺序编号，因此数字就是阅读顺序。
int blockOrderOf(String blockId) {
  if (blockId.length > 1 && blockId.codeUnitAt(0) == 0x62 /* b */) {
    final index = int.tryParse(blockId.substring(1));
    if (index != null) return index;
  }
  // 认不出来的块 ID（例如章题装饰块）排在章首之前，不会挤进正文中间
  return -1;
}

/// 阅读顺序比较：负数表示 [a] 在前。
///
/// 章内块序 + 块内偏移 + 倾向；跨章先比章节序号。
int compareLocators(
  Locator a,
  Locator b, {
  required Map<String, int> chapterOrdinals,
}) {
  final byChapter = _ordinalOf(a, chapterOrdinals)
      .compareTo(_ordinalOf(b, chapterOrdinals));
  if (byChapter != 0) return byChapter;
  final byBlock = blockOrderOf(a.blockId).compareTo(blockOrderOf(b.blockId));
  if (byBlock != 0) return byBlock;
  final byOffset = a.utf16Offset.compareTo(b.utf16Offset);
  if (byOffset != 0) return byOffset;
  return a.affinity.value.compareTo(b.affinity.value);
}

/// 把选区两端按阅读顺序排好（同一个选区不管是正着拖还是反着拖，结果一样）。
SelectionRange normalizeRange(
  SelectionRange range, {
  required Map<String, int> chapterOrdinals,
}) =>
    compareLocators(
          range.start,
          range.end,
          chapterOrdinals: chapterOrdinals,
        ) <=
        0
    ? range
    : SelectionRange(start: range.end, end: range.start);

/// 两个选区有没有交集（按阅读顺序；只有端点相接不算）。
///
/// 「点到已有高亮」和「保存时合并相交的高亮」都按这条规则找相关记录：
/// 位置相交就是同一处标注，不摘录文字比较（同一段话在书里可能出现多次）。
bool rangesIntersect(
  SelectionRange a,
  SelectionRange b, {
  required Map<String, int> chapterOrdinals,
}) {
  final first = normalizeRange(a, chapterOrdinals: chapterOrdinals);
  final second = normalizeRange(b, chapterOrdinals: chapterOrdinals);
  return compareLocators(
            first.start,
            second.end,
            chapterOrdinals: chapterOrdinals,
          ) <
          0 &&
      compareLocators(
            second.start,
            first.end,
            chapterOrdinals: chapterOrdinals,
          ) <
          0;
}

/// 两个选区的并集：起点取更早的那个、终点取更晚的那个（按阅读顺序）。
SelectionRange unionRange(
  SelectionRange a,
  SelectionRange b, {
  required Map<String, int> chapterOrdinals,
}) {
  final first = normalizeRange(a, chapterOrdinals: chapterOrdinals);
  final second = normalizeRange(b, chapterOrdinals: chapterOrdinals);
  return SelectionRange(
    start: compareLocators(
              first.start,
              second.start,
              chapterOrdinals: chapterOrdinals,
            ) <=
            0
        ? first.start
        : second.start,
    end: compareLocators(
              first.end,
              second.end,
              chapterOrdinals: chapterOrdinals,
            ) >=
            0
        ? first.end
        : second.end,
  );
}

/// 一段选区的最终形态：两端排好并对齐到字素边界，摘取自完整正文。
class ResolvedSelection {
  const ResolvedSelection({required this.range, required this.quote});

  /// 规范化后的选区（左闭右开，两端按阅读顺序）
  final SelectionRange range;

  /// 完整选文：跨段保留换行，图片与装饰块不进文字
  final String quote;

  /// 选区是否跨了章节
  bool get spansChapters => range.start.chapterId != range.end.chapterId;
}

/// 规范化选区并取出摘录。
///
/// [chapters] 是这本书的章节表（提供阅读顺序），
/// [contentOf] 按章节 ID 给正文——只有选区跨到的章节会被问到，
/// 同一章只问一次（外面不必自己缓存）。
ResolvedSelection resolveSelection({
  required SelectionRange selection,
  required List<Chapter> chapters,
  required ChapterContent Function(String chapterId) contentOf,
}) {
  final cache = <String, ChapterContent>{};
  ChapterContent content(String chapterId) =>
      cache.putIfAbsent(chapterId, () => contentOf(chapterId));

  final ordinals = chapterOrdinalsOf(chapters);
  final ordered = normalizeRange(selection, chapterOrdinals: ordinals);
  final start = _snapEnd(ordered.start, content);
  final end = _snapEnd(ordered.end, content);
  final range = SelectionRange(start: start, end: end);
  return ResolvedSelection(
    range: range,
    quote: extractQuote(range: range, chapters: chapters, contentOf: content),
  );
}

/// 把选区一端对齐到字素簇边界（不拆开 emoji 与组合字符），
/// 并按最终偏移重新生成 Locator：摘录与前后文必须跟最终位置对得上。
Locator _snapEnd(Locator locator, ChapterContent Function(String) contentOf) {
  final content = contentOf(locator.chapterId);
  for (final block in content.blocks) {
    if (block.id != locator.blockId) continue;
    final snapped = snapToGrapheme(blockTextOf(block), locator.utf16Offset);
    return LocatorMapper(
      bookId: locator.bookId,
      contentVersion: locator.contentVersion,
      chapterId: locator.chapterId,
    ).at(block, snapped, affinity: locator.affinity);
  }
  // 章里没有这一块：正文版本变过，保留原值，交给重新定位流程（L3）处理
  return locator;
}

/// 按阅读顺序把 [range] 覆盖的正文拼成摘录。
///
/// 同一块内截取两端；跨块的中间块整段取；跨章时逐章拼接。
/// 段落之间补一个换行，图片块（没有文字）不产生空行。
String extractQuote({
  required SelectionRange range,
  required List<Chapter> chapters,
  required ChapterContent Function(String chapterId) contentOf,
}) {
  final ordinals = chapterOrdinalsOf(chapters);
  final ordered = normalizeRange(range, chapterOrdinals: ordinals);
  final startOrdinal = _ordinalOf(ordered.start, ordinals);
  final endOrdinal = _ordinalOf(ordered.end, ordinals);
  final buffer = StringBuffer();
  for (final chapter in chapters) {
    if (chapter.ordinal < startOrdinal || chapter.ordinal > endOrdinal) continue;
    final text = _sliceChapter(
      contentOf(chapter.id),
      from: chapter.id == ordered.start.chapterId ? ordered.start : null,
      to: chapter.id == ordered.end.chapterId ? ordered.end : null,
    );
    if (text.isEmpty) continue;
    if (buffer.isNotEmpty) buffer.write('\n');
    buffer.write(text);
  }
  return buffer.toString();
}

/// 取一章里的 [from, to) 区间；两端为空表示整章（跨章选区中间的章节）。
///
/// [from] / [to] 指的是同一章内的两个位置；块按正文顺序遍历，
/// 找到起点块才开始收，遇到终点块就收尾。
String _sliceChapter(ChapterContent content, {Locator? from, Locator? to}) {
  final parts = <String>[];
  var started = from == null;
  for (final block in content.blocks) {
    final text = blockTextOf(block);
    if (!started) {
      if (block.id != from!.blockId) continue;
      started = true;
      if (to != null && to.blockId == block.id) {
        final slice = _slice(text, from.utf16Offset, to.utf16Offset);
        if (slice.isNotEmpty) parts.add(slice);
        return parts.join('\n');
      }
      final slice = _slice(text, from.utf16Offset, text.length);
      if (slice.isNotEmpty) parts.add(slice);
      continue;
    }
    if (to != null && block.id == to.blockId) {
      final slice = _slice(text, 0, to.utf16Offset);
      if (slice.isNotEmpty) parts.add(slice);
      return parts.join('\n');
    }
    if (text.isNotEmpty) parts.add(text);
  }
  return parts.join('\n');
}

/// 块内截取，两端先夹到字素边界，再夹进文本长度。
String _slice(String text, int from, int to) {
  final start = snapToGrapheme(text, from);
  final end = snapToGrapheme(text, to);
  if (end <= start) return '';
  return text.substring(start, end);
}

int _ordinalOf(Locator locator, Map<String, int> ordinals) =>
    ordinals[locator.chapterId] ?? kUnknownChapterOrdinal;
