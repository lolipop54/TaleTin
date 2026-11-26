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
  if (content.displaySourceJson?['coverPage'] == true) return const {};
  final known = _spreadChapterBlocks[tree];
  if (known != null) return known;
  final ranges =
      content.displaySourceJson?['spreadChapters'] as List? ?? const [];
  final titles =
      content.displaySourceJson?['tocSpreadStarts'] as List? ?? const [];
  final starts = {
    for (final range in ranges) range.first as int,
    ...titles.cast<int>(),
  }.toList()..sort();
  final indices = <int>{};
  for (var at = 0; at < starts.length; at++) {
    final start = starts[at];
    final explicitEnd = ranges
        .where((range) => range.first == start)
        .map((range) => range.last as int)
        .lastOrNull;
    final next = at + 1 < starts.length
        ? starts[at + 1]
        : content.blocks.length;
    final end = (explicitEnd ?? next - 1).clamp(start, next - 1);
    int? firstVisible;
    for (var i = start; i <= end; i++) {
      if (tree.hiddenBlocks.contains(i)) continue;
      firstVisible ??= i;
      final block = content.blocks[i];
      if (block.kind != BlockKind.caption && block.runLength > 0) {
        indices.add(firstVisible);
        break;
      }
    }
  }
  return _spreadChapterBlocks[tree] = {
    for (final i in indices) content.blocks[i].id,
  };
}

extension SpreadChapterBoundaries on ChapterLayout {
  DisplayTree get _spreadTree =>
      task?._wholeDisplayTree ??
      (identical(task?._source.content, content)
          ? task!._displayTree
          : (_locatorDisplayTree ??= DisplayTree.build(content)));

  /// 源文档明示的章节和正文核实过的目录章首可以开启一组双页。
  Set<String> get spreadStarts => options.spreadDocumentChapters
      ? _spreadStarts(content, options, _spreadTree)
      : const {};

  String? get lastDeclaredSpreadStart => !options.spreadDocumentChapters
      ? null
      : task?._indexedSections?.lastChapterStart ?? spreadStarts.lastOrNull;

  String? spreadSectionAt(int pageIndex) {
    final blockId = page(pageIndex)?.start.blockId;
    if (blockId == null) return null;
    final indexed = task?._indexedSections;
    if (indexed != null && options.spreadDocumentChapters) {
      final start = indexed.chapterStartFor(blockId);
      if (start != null) return start;
    }
    if (spreadStarts.isEmpty) return null;
    final tree = _spreadTree;
    final pageBlock = tree.blockIndexById[page(pageIndex)?.start.blockId];
    if (pageBlock == null) return null;
    return spreadStarts
        .where((id) => tree.blockIndexById[id]! <= pageBlock)
        .lastOrNull;
  }

  /// 跨段的双页只累计所属真实章首到目标之间的页数。
  Future<int> pageOffsetFrom(
    int pageIndex,
    String? block, {
    LayoutToken? token,
  }) async {
    final owner = task;
    final window = _txtWindow;
    final sections = owner?._indexedSections;
    if (block == null || owner == null || window == null || sections == null) {
      return await physicalPageNumber(pageIndex, token: token) -
          await sectionStartPage(block);
    }
    final first = sections.forBlock(block);
    if (first == window) return pageIndex - await sectionStartPage(block);
    owner._pinnedTxtWindows.update(window, (n) => n + 1, ifAbsent: () => 1);
    try {
      var count = await owner._verifiedWindowTail(first, block, token);
      if (count == null) {
        final start = await owner.ensure(
          txtWindow: first,
          atEnd: true,
          token: token,
        );
        count = start.pageCount - await start.sectionStartPage(block);
      }
      for (var i = first + 1; i < window; i++) {
        count = count! + await owner._countSectionWindow(i, token);
      }
      await owner.ensure(
        txtWindow: window,
        page: pageIndex,
        lookAhead: 0,
        token: token,
      );
      return count! + pageIndex - firstPage;
    } finally {
      if (owner._pinnedTxtWindows[window] == 1) {
        owner._pinnedTxtWindows.remove(window);
      } else {
        owner._pinnedTxtWindows[window] = owner._pinnedTxtWindows[window]! - 1;
      }
    }
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
    final current = pageIndexOf(point);
    if (current != null) return current;
    final resolved = await ensureTarget(point);
    return resolved.pageIndexOf(point) ?? resolved.firstPage;
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
