part of 'chapter_layout.dart';

extension ChapterTailCount on ChapterLayoutTask {
  /// Counts the pages of one real chapter through the end of its source file.
  /// A null result asks the caller to paginate normally to find the boundary.
  Future<int?> verifiedChapterTail(String blockId, LayoutToken? token) async {
    final sections = _indexedSections;
    if (sections == null || sections.lastChapterStart != blockId) return null;
    _foreground++;
    try {
      final start = sections.forBlock(blockId);
      final tail = await _verifiedWindowTail(start, blockId, token);
      if (tail == null) return null;
      var total = tail;
      for (var i = start + 1; i < sections.count; i++) {
        total += await _countSectionWindow(i, token);
      }
      return total;
    } finally {
      _foreground--;
    }
  }

  Future<int> _countSectionWindow(int window, LayoutToken? token) async {
    final known =
        _windowPageCounts[window] ??
        await knownWindow?.call(window, _windowOffset(window), _txtWindowCount);
    _checkActive(token);
    if (known != null) return known;
    final source = await _sectionCountSource(window, token);
    final count = await _countFrom(source, _windowOffset(window), 0, token);
    _rememberCount(window, count);
    return count;
  }

  void _rememberCount(int window, int pages) {
    _windowPageCounts[window] = pages;
    onExactPages?.call((
      chapter: chapter.ordinal,
      window: window,
      offset: _windowOffset(window),
      windows: _txtWindowCount,
      pages: pages,
    ));
  }

  Future<_LazyMeasuredBlocks> _sectionCountSource(
    int window,
    LayoutToken? token, {
    String? from,
  }) async {
    final cached = _windowReady && _txtWindow == window
        ? _source
        : _recentTxtWindows[window]?.source;
    final body =
        cached?.content ?? await _indexedSections!.readSectionForCount(window);
    final active =
        cached?.options ?? await prepareSectionOptions?.call(body) ?? options;
    _checkActive(token);
    final content = cached == null
        ? CssLayoutStyles.resolve(body, active)
        : body;
    final tree = cached?.measurer.displayTree ?? DisplayTree.build(content);
    final index = tree.blockIndexById[from] ?? 0;
    return _LazyMeasuredBlocks(
      chapter,
      content,
      active,
      measurementCache,
      cacheEnabled: false,
      countOnly: true,
      displayTree: tree,
      startBlock: index > 0 ? index - 1 : 0,
      includeChapterTitle: window == 0 && index == 0,
    );
  }

  Future<int?> _verifiedWindowTail(
    int window,
    String blockId,
    LayoutToken? token,
  ) async {
    _checkActive(token);
    if (_windowTailCounts[blockId] case final known?) return known;
    final source = await _sectionCountSource(window, token, from: blockId);
    final tree = source.measurer.displayTree!;
    final index = tree.blockIndexById[blockId];
    if (index == null ||
        !_spreadStarts(source.content, options, tree).contains(blockId)) {
      return null;
    }
    if (index == 0) {
      // A verified chapter on the first flowing row uses the full window count.
      // Decorations and absolute page images can otherwise own an earlier page.
      if (tree.emptyAt.containsKey(0) ||
          (_windowOffset(window) == 0 &&
              source.measurer.pageImagesOf(source.content).isNotEmpty) ||
          (source.includeChapterTitle &&
              source.options.insertChapterTitle &&
              !source._contentTitle)) {
        return null;
      }
      await source.measurer.prepareMath(source.content);
      if (!source.has(0) || !_ordinaryStart(source[0], blockId, image: true)) {
        return null;
      }
      if (_windowPageCounts[window] case final count?) return count;
      final count = await _countFrom(source, _windowOffset(window), 0, token);
      _rememberCount(window, count);
      return _windowTailCounts[blockId] = count;
    }

    // A neighboring ordinary text block proves there was a page before this
    // forced break. Retain it for the same margin and box join at the heading.
    final before = source.content.blocks[index - 1];
    if (before.kind != BlockKind.paragraph && before.kind != BlockKind.quote) {
      return null;
    }
    if (source._parallel.ends.entries.any(
          (e) => e.key < index && index - 1 <= e.value,
        ) ||
        (index == 1 && source.options.insertChapterTitle)) {
      return null;
    }
    final sizing = ContainerFlowSizing.build(
      tree,
      ChapterStyler.layoutTableOf(source.content),
      options,
    );
    if (sizing?.canRestartAt(blockId, 0) == false) return null;
    await source.measurer.prepareMath(source.content);
    _checkActive(token);
    if (!source.has(1) ||
        !_ordinaryStart(source[0], before.id) ||
        source[0].kind != before.kind ||
        (source[0].boxId != null && source[0].box != null) ||
        !_ordinaryStart(source[1], blockId)) {
      return null;
    }
    return _windowTailCounts[blockId] = await _countFrom(source, 1, 1, token);
  }

  bool _ordinaryStart(MeasuredBlock block, String id, {bool image = false}) =>
      block.blockId == id &&
      !block.isDecoration &&
      !block.collapsesThrough &&
      !block.positionedOverlay &&
      !block.isPageImage &&
      block.pageTop == null &&
      block.tableId == null &&
      (block.lines.isNotEmpty || (image && block.imageSize != null));

  Future<int> _countFrom(
    _LazyMeasuredBlocks source,
    int firstPage,
    int firstBlock,
    LayoutToken? token,
  ) async {
    var pages = 0;
    final batch = Stopwatch()..start();
    await source.measurer.prepareMath(source.content);
    _checkActive(token);
    final steps = _paginator(source, firstPage).steps(
      source,
      firstPage: firstPage,
      firstBlock: firstBlock,
      onPageSealed: () => pages++,
      releaseBefore: source.releaseBefore,
    );
    // Use an event-queue message to let input/frames run without arming a
    // timer for every few milliseconds of an otherwise synchronous count.
    RawReceivePort? yieldPort;
    try {
      for (final _ in steps) {
        if (batch.elapsedMicroseconds < 4000) continue;
        final resume = Completer<void>();
        final port = yieldPort ??= RawReceivePort();
        port.handler = (_) => resume.complete();
        port.sendPort.send(null);
        await resume.future;
        _checkActive(token);
        batch.reset();
      }
    } finally {
      yieldPort?.close();
    }
    return pages;
  }
}
