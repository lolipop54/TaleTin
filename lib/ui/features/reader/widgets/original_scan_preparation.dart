part of 'original_reader_area.dart';

extension _OriginalScanPreparation on _OriginalReaderAreaState {
  Future<ScanPreparation> _prepareScan(ValueChanged<ui.Image> cover,
      PageInformation information, Size size) async {
    _preload.hold('scan-prepare');
    try {
      return await _prepareScanFrames(cover, information, size);
    } finally {
      _preload.requestChapter(null);
      _preload.release('scan-prepare');
    }
  }

  Future<ScanPreparation> _prepareScanFrames(ValueChanged<ui.Image> cover,
      PageInformation information, Size size) async {
    // 普通翻页预取可能临时切页，必须等还原后再取得当前页。
    await _curlKey.currentState?.settleForSpeech();
    final host = _host!;
    final navigation = _navigation;
    await host.preparation;
    final page = await host.page;
    final current = ScanFrames.withInformation(await host.capture(),
      information, size, widget.theme.background);
    ui.Image? next;
    OriginalTurnTarget? target;
    Locator? anchor;
    try {
      cover(current);
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted || navigation != _navigation) throw StateError('阅读位置已改变');
      final last = widget.session.chapterIndex == widget.session.chapters.length - 1 &&
          await host.adjacentPage(1) == null;
      target = last ? null : await _resolveCurlTarget(false);
      if (target != null) {
        final map = await _scanHighlights(target.chapter, target.host);
        next = ScanFrames.withInformation(await target.host.capturePage(target.page),
          target.information!, size, widget.theme.background);
        final point = await target.host.scanPageAnchor();
        if (point != null) anchor = map.locatorAt(point);
      }
      final destination = target;
      return ScanPreparation(ScanFrames(current, next), destination == null ? null : () async {
        if (!mounted || navigation != _navigation || host != _host) {
          throw StateError('阅读位置已改变');
        }
        if (!await _commitCurl(destination)) throw StateError('下一页未能落位');
        await WidgetsBinding.instance.endOfFrame;
        await destination.host.presented();
        if (anchor != null && mounted) {
          await ref.read(readerSessionProvider(widget.bookId).notifier)
            .commitOriginalScanPosition(anchor, await destination.host.fractionForPage(destination.page));
        }
      }, targetPage: destination == null ? null : (destination.chapter, destination.page, navigation));
    } catch (_) { current.dispose(); next?.dispose(); rethrow; }
    finally {
      if (mounted && navigation == _navigation && target?.host == host) {
        await host.previewPage(page);
        await host.presented();
      }
    }
  }

  /// 离屏章的截图也必须含持久高亮，不能等它成为当前章后才补底色。
  Future<OriginalSelectionMap> _scanHighlights(int ordinal, OriginalHostController host) async {
    final chapter = widget.session.chapters[ordinal];
    final content = await ref.read(chapterContentRepositoryProvider).chapter(widget.bookId, chapter);
    final anchors = await widget.controller.positionMap(ordinal, chapter.href!, content,
      Locator(bookId: widget.bookId, contentVersion: widget.session.book.contentVersion,
        chapterId: chapter.id, blockId: '', utf16Offset: 0));
    if (!mounted) throw StateError('阅读页已关闭');
    final map = OriginalSelectionMap(map: anchors, content: content);
    final items = <Map<String, Object?>>[];
    final ordinals = chapterOrdinalsOf(widget.session.chapters);
    for (final annotation in ref.read(annotationsProvider(widget.bookId)).value ?? <Annotation>[]) {
      if (annotation.isBookmark || annotation.color == null) continue;
      final end = annotation.end ?? annotation.start;
      final first = ordinals[annotation.start.chapterId], last = ordinals[end.chapterId];
      if (first == null || last == null || ordinal < first || ordinal > last) continue;
      final from = first == ordinal ? map.pointOf(annotation.start) : map.chapterEdgePoint(atEnd: false);
      final to = last == ordinal ? map.pointOf(end, end: true) : map.chapterEdgePoint(atEnd: true);
      if (from == null || to == null) continue;
      items.add({'id': annotation.id, 'from': from, 'to': to,
        'color': hexOf(highlightColorOf(annotation.color)),
        'hasThought': annotation.body.trim().isNotEmpty && last == ordinal,
        'thoughtColor': hexOf(readingLinkColor(widget.theme))});
    }
    await host.setHighlights(items, ++_highlightVersion);
    return map;
  }
}
