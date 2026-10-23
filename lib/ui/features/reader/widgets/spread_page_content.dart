part of '../views/reader_view.dart';

extension _SpreadPageContent on _ReaderSpreadAreaState {
  Offset _origin(SpreadPageRef page, int side) {
    final info = readerInformation(
      context,
      ref,
      widget.session,
      widget.settings.settings,
      widget.settings.theme,
      widget.session.chapterIndex,
      widget.session.chapterProgress,
    );
    return Offset(
      side * _size.width / 2 +
          (_size.width / 2 - page.layout.contentSize.width) / 2,
      (_size.height - page.layout.contentSize.height + info.top - info.bottom) /
          2,
    );
  }

  /// 同一个文字边界可能同时属于左页末和右页首。两页都可见时只保留
  /// 与高亮相接的一处；真正翻到不可见的相邻页时，仍可从该页继续扩选。
  ({int side, CaretGeometry caret})? _spreadCaret(
    _SpreadPair pair,
    Locator locator,
    bool atEnd,
  ) {
    final engine = ref.read(readerEngineProvider);
    final range = ref.read(readerProvider).selection;
    final reversed =
        range != null &&
        compareLocators(
              range.start,
              range.end,
              chapterOrdinals: chapterOrdinalsOf(widget.session.chapters),
            ) >
            0;
    final trailing = reversed ? !atEnd : atEnd;
    ({int side, CaretGeometry caret})? result;
    for (final (page, side) in [
      (pair.left, 0),
      if (pair.right != null) (pair.right!, 1),
    ]) {
      final caret = engine.caretAt(
        page.layout,
        page.pageIndex,
        locator,
        atEnd: trailing,
      );
      if (caret == null) continue;
      result = (side: side, caret: caret);
      if (trailing) break;
    }
    return result;
  }

  Rect _selectionBounds(_SpreadPair pair) {
    final last = pair.right ?? pair.left;
    return Rect.fromPoints(
      _origin(pair.left, 0),
      _origin(last, pair.right == null ? 0 : 1) +
          last.layout.contentSize.bottomRight(Offset.zero),
    );
  }

  List<({Annotation annotation, List<Rect> rects})> _marks(SpreadPageRef page) {
    final ordinals = chapterOrdinalsOf(widget.session.chapters);
    final engine = ref.read(readerEngineProvider);
    return [
      for (final a in ref.read(readerHighlightsProvider(widget.bookId)))
        if (!a.isBookmark && a.color != null)
          (
            annotation: a,
            rects: engine.selectionRects(
              page.layout,
              page.pageIndex,
              a.start,
              a.end ?? a.start,
              chapterOrdinals: ordinals,
            ),
          ),
    ];
  }

  PageCanvas _canvas(SpreadPageRef page, int side, {required bool current}) {
    final settings = widget.settings.settings;
    final state = ref.read(readerProvider);
    final engine = ref.read(readerEngineProvider);
    final selection = state.selection;
    final marks = _marks(page);
    final unit = ref.read(listeningViewStateProvider).value?.activeUnit;
    final infoSettings = settings;
    final pair = current ? _pair : _target;
    bool marked(SpreadPageRef p) =>
        ref
            .read(bookmarksProvider(widget.bookId))
            .value
            ?.any(
              (m) =>
                  m.locator.chapterId == p.layout.chapterId &&
                  p.layout.pageIndexOf(m.locator) == p.pageIndex,
            ) ??
        false;
    return PageCanvas(
      layout: page.layout,
      pageIndex: page.pageIndex,
      theme: widget.settings.theme,
      textCache: _text,
      information: readerInformation(
        context,
        ref,
        widget.session,
        infoSettings,
        widget.settings.theme,
        widget.session.chapters.indexWhere(
          (c) => c.id == page.layout.chapterId,
        ),
        page.layout.progressOfPage(page.pageIndex),
        spreadSide: side,
        showReturnProgress: false,
        bookmarked:
            side == 1 &&
            (pair == null
                ? marked(page)
                : marked(pair.left) ||
                      (pair.right != null && marked(pair.right!))),
      ),
      selectionRects: selection == null || state.selectionFromMark
          ? const []
          : engine.selectionRects(
              page.layout,
              page.pageIndex,
              selection.start,
              selection.end,
              chapterOrdinals: chapterOrdinalsOf(widget.session.chapters),
            ),
      selectionHandles: [
        if (selection != null && !state.selectionFromMark)
          for (final end in [false, true])
            if (end != _draggedSelectionEnd)
              if (pair != null)
                if (_spreadCaret(
                      pair,
                      end ? selection.end : selection.start,
                      end,
                    )
                    case final position? when position.side == side)
                  position.caret,
      ],
      handleColor: context.gtColors.actionPrimary,
      highlights: [
        for (final m in marks)
          PageHighlight(
            color: pageHighlightColorOf(m.annotation.color),
            rects: m.rects,
          ),
      ],
      thoughtMarkers: [
        for (final m in marks)
          if (m.rects.isNotEmpty &&
              m.annotation.body.trim().isNotEmpty &&
              m.annotation.end != null &&
              engine.caretAt(
                    page.layout,
                    page.pageIndex,
                    m.annotation.end!,
                    atEnd: true,
                  ) !=
                  null)
            PageThoughtMarker(
              id: m.annotation.id,
              rect: thoughtMarkerRect(
                m.rects.last,
                page.layout.contentSize.width,
              ),
              color: readingLinkColor(widget.settings.theme),
            ),
      ],
      speechRects: unit == null
          ? const []
          : speechRectsForPage(
              layout: page.layout,
              pageIndex: page.pageIndex,
              from: unit.sentenceStart,
              to: unit.sentenceEnd,
            ),
      resolveResource: (path) => ref
          .read(chapterContentRepositoryProvider)
          .resourceAbsolutePath(
            widget.bookId,
            widget.session.book.contentVersion,
            path,
          ),
    );
  }

  (SpreadPageRef, int)? _hit(Offset point) {
    final pair = _pair;
    if (pair == null) return null;
    final side = point.dx < _size.width / 2 ? 0 : 1;
    final page = side == 0 ? pair.left : pair.right;
    return page == null ? null : (page, side);
  }

  Future<void> _select(Offset point, {bool extend = false}) async {
    await ref.read(automaticReadingProvider(widget.bookId).notifier).discard();
    if (!mounted || !isReady || _moving) return;
    final hit = _hit(point);
    if (hit == null) return;
    final (page, side) = hit;
    final local = point - _origin(page, side);
    final engine = ref.read(readerEngineProvider);
    final vm = ref.read(readerProvider.notifier);
    if (extend && ref.read(readerProvider).selection != null) {
      final locator = engine.locatorAtPoint(page.layout, page.pageIndex, local);
      if (locator != null) vm.extendSelection(locator);
    } else {
      final range = engine.sentenceRangeAtPoint(
        page.layout,
        page.pageIndex,
        local,
      );
      if (range != null) vm.startSelection(range.start, range.end);
    }
  }

  Future<bool> _tap(Offset point) async {
    final auto = ref.read(automaticReadingProvider(widget.bookId).notifier);
    if (auto.consumePauseTap()) return true;
    final state = ref.read(readerProvider);
    if (state.controlsVisible) {
      ref.read(readerProvider.notifier).closePanel();
      return true;
    }
    if (state.selection != null) {
      ref.read(readerProvider.notifier).clearSelection();
      return true;
    }
    final hit = _hit(point);
    if (hit == null) return false;
    final (page, side) = hit;
    final origin = _origin(page, side);
    final local = point - origin;
    final canvas = _canvas(page, side, current: true);
    for (final marker in canvas.thoughtMarkers) {
      if (!marker.rect.inflate(8).contains(local)) continue;
      final note = ref
          .read(readerHighlightsProvider(widget.bookId))
          .firstWhere((a) => a.id == marker.id);
      if (!mounted) return true;
      final box = context.findRenderObject()! as RenderBox;
      await showThoughtPopover(
        context,
        body: note.body,
        theme: widget.settings.theme,
        anchor: marker.rect.shift(box.localToGlobal(origin)),
      );
      return true;
    }
    for (final mark in _marks(page)) {
      if (mark.annotation.id != searchPreviewId &&
          mark.rects.any((r) => r.inflate(2).contains(local))) {
        ref
            .read(readerProvider.notifier)
            .startSelection(
              mark.annotation.start,
              mark.annotation.end ?? mark.annotation.start,
              fromMark: true,
            );
        return true;
      }
    }
    for (final f in page.layout.page(page.pageIndex)!.fragments) {
      final image = f.imageSize, path = f.block.resourcePath;
      if (f.frameOnly ||
          image == null ||
          path == null ||
          !(Offset(f.block.tableId == null ? 0 : f.block.inset, f.y) & image)
              .contains(local)) {
        continue;
      }
      if (!mounted) return true;
      if (await tryReaderImageGallery(
        context,
        ref,
        widget.bookId,
        path,
        chapterId: page.layout.chapterId,
        blockId: f.block.blockId,
      )) {
        return true;
      }
      if (!mounted) return true;
      final file = File(canvas.resolveResource(path));
      if (path.toLowerCase().endsWith('.svg')) {
        await showReaderSvg(context, SvgFileLoader(file));
      } else {
        await showReaderImage(context, FileImage(file));
      }
      return true;
    }
    return false;
  }

  List<Widget> _selectionLayers(_SpreadPair pair, ReaderState state) {
    final engine = ref.read(readerEngineProvider);
    final rects = <Rect>[];
    final result = <Widget>[];
    for (final (page, side) in [
      (pair.left, 0),
      if (pair.right != null) (pair.right!, 1),
    ]) {
      final origin = _origin(page, side);
      rects.addAll(
        engine
            .selectionRects(
              page.layout,
              page.pageIndex,
              state.selection!.start,
              state.selection!.end,
              chapterOrdinals: chapterOrdinalsOf(widget.session.chapters),
            )
            .map((r) => r.shift(origin)),
      );
    }
    if (!state.selectionFromMark) {
      result.add(
        Positioned.fill(
          child: SelectionHandles(
            bookId: widget.bookId,
            state: state,
            layout: pair.left.layout,
            pageIndex: pair.left.pageIndex,
            origin: Offset.zero,
            theme: widget.settings.theme,
            paintIdleHandles: false,
            selectionSize: _size,
            selectionBounds: _selectionBounds(pair),
            onDragChanged: _selectionDragChanged,
            caretAt: (locator, atEnd) {
              final current = _pair!;
              final position = _spreadCaret(current, locator, atEnd);
              if (position == null) return null;
              final origin = _origin(
                position.side == 0 ? current.left : current.right!,
                position.side,
              );
              return CaretGeometry(
                left: position.caret.left + origin.dx,
                top: position.caret.top + origin.dy,
                height: position.caret.height,
              );
            },
            locatorAt: (point) {
              final hit = _hit(point);
              if (hit == null) return null;
              return engine.locatorAtPoint(
                hit.$1.layout,
                hit.$1.pageIndex,
                point - _origin(hit.$1, hit.$2),
              );
            },
            turnSelection: (forward) async {
              final before = _pair;
              await turn(forward);
              if (!mounted || _pair == before) return null;
              final edge = forward
                  ? _pair!.left
                  : (_pair!.right ?? _pair!.left);
              return engine.pageEdge(
                edge.layout,
                edge.pageIndex,
                atEnd: !forward,
              );
            },
          ),
        ),
      );
    }
    if (!_moving) {
      result.add(
        Positioned.fill(
          child: SelectionActions(
            bookId: widget.bookId,
            state: state,
            rects: rects,
            origin: Offset.zero,
            pageSize: _size,
          ),
        ),
      );
    }
    return result;
  }
}
