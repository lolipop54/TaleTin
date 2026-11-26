part of 'chapter_layout.dart';

/// 独立引擎只消费阅读器同一个分页迭代器。页首确定就能计数，
/// 不保留整章页列表、翻页图片和前台断点。
Future<List<int>> countChapterPages({
  required LayoutRequestForCount input,
  void Function(PageSlice page)? onPage,
  void Function(int pages)? onCount,
  int? Function(int window, int offset, int windows)? knownPages,
  void Function(ExactPageCount)? onExactWindow,
  void Function(int pages)? onWindowComplete,
  required Future<void> Function() yieldToControls,
  Future<LayoutOptions> Function(ChapterContent)? prepareSectionOptions,
}) async {
  await EnglishHyphenation.prepare();
  var count = 0;
  void sealed() {
    count++;
    onCount?.call(1);
  }

  final task = ChapterLayoutTask(
    bookId: input.bookId,
    contentVersion: input.version,
    chapter: input.chapter,
    content: input.content,
    indexedSections: input.sections,
    prepareSectionOptions: prepareSectionOptions,
    options: input.options,
    onPageSealed: onPage == null ? sealed : null,
  );
  try {
    final counts = <int>[];
    final batch = Stopwatch()..start();
    for (
      var window = 0;
      window == 0 || window < task._txtWindowCount;
      window++
    ) {
      final windows = task._txtWindowCount == 0 ? 1 : task._txtWindowCount;
      final offset = task._windowOffset(window);
      int? known() => knownPages?.call(window, offset, windows);
      var exact = known();
      count = 0;
      if (exact == null) {
        if (task._txtWindowCount > 0) await task._selectTxtWindow(window, null);
        await task._source.measurer.prepareMath(task.content);
        while (task._steps.moveNext()) {
          final page = task._steps.current;
          if (page != null) {
            sealed();
            onPage!(page);
          }
          if (batch.elapsedMilliseconds >= 6) {
            await yieldToControls();
            batch.reset();
            exact = known();
            if (exact != null) break;
          }
        }
      }
      if (exact != null) {
        // 前台可能在本节已上报几页后到达，只补差额。
        if (exact != count) onCount?.call(exact - count);
        count = exact;
      } else if (task._txtWindowCount > 0) {
        onExactWindow?.call((
          chapter: input.chapter.ordinal,
          window: window,
          offset: offset,
          windows: windows,
          pages: count,
        ));
      }
      counts.add(count);
      if (task._txtWindowCount > 1) onWindowComplete?.call(count);
    }
    return counts;
  } finally {
    task.dispose();
  }
}

typedef LayoutRequestForCount = ({
  String bookId,
  int version,
  Chapter chapter,
  ChapterContent? content,
  ChapterSections? sections,
  LayoutOptions options,
});
