part of 'chapter_layout.dart';

final _spreadChapterBlocks = Expando<Set<String>>();

// 章首范围使用原文块号。隐藏的章题顺延到本章第一个可见块，整章隐藏就跳过。
Set<String> _spreadStarts(
  ChapterContent content,
  LayoutOptions options,
  DisplayTree tree,
) {
  if (!options.settings.spreadEnabled || !options.spreadDocumentChapters) {
    return const {};
  }
  final ranges = content.displaySourceJson?['spreadChapters'];
  if (ranges is! List || ranges.isEmpty) return const {};
  final known = _spreadChapterBlocks[content];
  if (known != null) return known;
  final indices = <int>{};
  var firstVisible = 0;
  while (tree.hiddenBlocks.contains(firstVisible)) {
    firstVisible++;
  }
  for (final range in ranges.cast<List>()) {
    for (var i = range.first as int; i <= (range.last as int); i++) {
      if (tree.hiddenBlocks.contains(i)) continue;
      if (i > firstVisible) indices.add(i);
      break;
    }
  }
  return _spreadChapterBlocks[content] = {
    for (final i in indices.toList()..sort()) content.blocks[i].id,
  };
}

extension SpreadChapterBoundaries on ChapterLayout {
  /// 文件内部只有原书明确标记的章首参与分组。
  Set<String> get spreadStarts => options.spreadDocumentChapters
      ? _spreadChapterBlocks[content] ?? const {}
      : const {};

  String? spreadSectionAt(int pageIndex) {
    if (spreadStarts.isEmpty) return null;
    final tree =
        task?._displayTree ??
        (_locatorDisplayTree ??= DisplayTree.build(content));
    final pageBlock = tree.blockIndexById[page(pageIndex)?.start.blockId];
    if (pageBlock == null) return null;
    return spreadStarts
        .where((id) => tree.blockIndexById[id]! <= pageBlock)
        .lastOrNull;
  }

  Future<int> sectionStartPage(String? block) async {
    if (block == null) return 0;
    final point = Locator(
      bookId: bookId,
      contentVersion: contentVersion,
      chapterId: chapterId,
      blockId: block,
      utf16Offset: 0,
    );
    return pageIndexOf(point) ??
        (await ensureTarget(point)).pageIndexOf(point)!;
  }

  /// TXT 小节的内部页号从文字偏移起算；仅用已经排完的小节累加真实页数。
  Future<int> physicalPageNumber(int pageIndex, {LayoutToken? token}) async {
    final window = _txtWindow;
    if (window == null) return pageIndex;
    final owner = task!;
    final starts = owner._windowPageStarts;
    if (starts.length <= window) {
      // 冷跳到很后的分节时，核实前面各节页数仍要保留屏幕上的原分页对象。
      final pinned = owner._pinnedTxtWindows;
      pinned.update(window, (n) => n + 1, ifAbsent: () => 1);
      try {
        while (starts.length <= window) {
          final previous = starts.length - 1;
          final count =
              owner._windowPageCounts[previous] ??
              await owner.knownWindow?.call(
                previous,
                owner._windowOffset(previous),
                owner._txtWindowCount,
              ) ??
              (await owner.ensure(
                txtWindow: previous,
                atEnd: true,
                token: token,
              )).pages.length;
          owner._checkActive(token);
          if (starts.length == previous + 1) starts.add(starts.last + count);
        }
        if (owner._txtWindow != window) {
          await owner.ensure(
            txtWindow: window,
            page: pageIndex,
            lookAhead: 0,
            token: token,
          );
        }
      } finally {
        if (pinned[window] == 1) {
          pinned.remove(window);
        } else {
          pinned[window] = pinned[window]! - 1;
        }
      }
    }
    return starts[window] + pageIndex - firstPage;
  }
}
