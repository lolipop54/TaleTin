part of 'simplified_scroll_area.dart';

extension on SimplifiedScrollAreaState {
  ScrollTextPainter _textPainter(ScrollChapter chapter, ScrollCell cell) {
    final areas = scrollBackgroundAreas(chapter, cell);
    final options = chapter.options ?? _window.options!;
    final theme = widget.settings.theme;
    final boxes = [
      cell.measured,
      for (final fragment in cell.table) fragment.block,
    ].expand(blockPaintBoxes);
    final hasImagesInText = boxes.any((b) => b.backgroundImage != null);
    // 文字指令缓存不持有图片和阴影像素，它们各自按屏幕大小管理。
    final cacheText =
        !hasImagesInText && !boxes.any((b) => b.shadows.isNotEmpty);
    final links = ReaderLinkInk.appearance(widget.bookId, chapter.content);
    return ScrollTextPainter(
      links: links,
      cell,
      options,
      theme.primary,
      theme.secondary,
      theme: theme,
      paintShadows: _shadows!.paint,
      pictures: cacheText ? _textPictures : null,
      paragraphs: _paragraphs,
      repaint: links == null
          ? (hasImagesInText ? _resources : null)
          : Listenable.merge([links.state, if (hasImagesInText) _resources]),
      paintImageBoxes: false,
      images: _resources.backgroundInfo,
      backgroundAreas: areas,
      backdrop: _resources.backdropOf(chapter, options, theme),
    );
  }

  // 只从已经排好的章节取相邻正文。首屏先显示，手指拖动和惯性动画优先。
  void _prepareNearbyText() {
    if (!mounted || !isReady || !_window.controller.hasClients) return;
    final position = _window.controller.position;
    if (!position.hasContentDimensions || position.isScrollingNotifier.value) {
      return;
    }
    final offsets = _window.cellOffsets;
    final top = position.pixels;
    final bottom = top + position.viewportDimension;
    // 平板快划一次就可能经过两三屏。只利用已排好的正文，优先最近的段落。
    final reach = position.viewportDimension * 12;
    Iterable<int> nearby() sync* {
      final first = scrollCellIndexAt(offsets, top);
      final last = scrollCellIndexAt(offsets, bottom);
      // 换章时，落在视口内的部分段落也可能尚未画过。已录过的直接命中。
      var count = 0;
      for (
        var i = first;
        i <= last && i < offsets.length - 1 && count < 128;
        i++
      ) {
        yield i;
        count++;
      }
      var before = first - 1;
      var after = last + 1;
      for (; count < 128; count++) {
        final up = before >= 0 ? top - offsets[before + 1] : double.infinity;
        final down = after < offsets.length - 1
            ? offsets[after] - bottom
            : double.infinity;
        if (math.min(up, down) > reach) break;
        yield down <= up ? after++ : before--;
      }
    }

    _nearbyText = nearby().iterator;
    _scheduleNextText();
  }

  void _scheduleNextText() {
    if (_textTaskScheduled || _nearbyText == null) return;
    _textTaskScheduled = true;
    Timer.run(() async {
      final candidates = _nearbyText;
      if (!mounted ||
          candidates == null ||
          !isReady ||
          !_window.controller.hasClients ||
          _window.controller.position.isScrollingNotifier.value) {
        _nearbyText = null;
        _textTaskScheduled = false;
        return;
      }
      final binding = SchedulerBinding.instance;
      if (binding.hasScheduledFrame) {
        // 已有一帧在等显示时，等它画完再尝试。不要用零延时任务轮询下一帧。
        binding.addPostFrameCallback((_) {
          _textTaskScheduled = false;
          if (mounted) _scheduleNextText();
        });
        return;
      }
      // 每次空闲任务最多录一个段落；输入、下一帧和跳章都可以打断剩下的工作。
      while (candidates.moveNext()) {
        final i = candidates.current;
        final entry = _window.cellAt(i);
        final cell = entry.cell;
        if (!cell.measured.isText ||
            cell.table.isNotEmpty ||
            cell.to - cell.from > 8 ||
            cell.to <= cell.from ||
            cell.measured.inlineImages.isNotEmpty) {
          continue;
        }
        final offsets = _window.cellOffsets;
        final size = Size(
          _window.options!.contentWidth,
          offsets[i + 1] - offsets[i],
        );
        final painter = _textPainter(entry.entry.layout, cell);
        if (painter.prepare(size)) {
          try {
            await _textPictures.warmGlyphs(
              painter._key(size),
              size,
              _shadows!.pixelRatio,
            );
          } finally {
            _textTaskScheduled = false;
            if (mounted) _scheduleNextText();
          }
          return;
        }
      }
      _nearbyText = null;
      _textTaskScheduled = false;
    });
  }
}

class ScrollTextPainter extends CustomPainter {
  ScrollTextPainter(
    this.cell,
    this.options,
    this.color,
    this.ruleColor, {
    this.theme,
    this.images,
    this.backgroundAreas = const {},
    this.paintImageBoxes = true,
    this.backdrop,
    this.pictures,
    this.paragraphs,
    this.paintShadows = paintBookShadows,
    this.links,
    super.repaint,
  });
  final LinkAppearance? links;
  final ScrollTextPictures? pictures;
  final MeasuredParagraphs? paragraphs;
  final BookShadowPainter paintShadows;
  final ReadingTheme? theme;
  final BookImageLookup? images;
  final Map<int, Rect> backgroundAreas;
  final Color? backdrop;
  final ScrollCell cell;
  final bool paintImageBoxes;
  final LayoutOptions options;
  final Color color;
  final Color ruleColor;
  // 浅色主题正文保留原书字色。章节背景取色完成时，只重录真正依赖底色的文字。
  Color? get _inkBackdrop =>
      cell.table.isNotEmpty ||
          ReaderTextPainter.usesBackdropForInk(theme ?? ReadingTheme.paper)
      ? backdrop
      : null;
  // 高度来自原单元格。列表窗口增删章节后，累计偏移相减可能有舍入差，
  // 不应因此重画同一个段落。横向分隔线仍使用当前画布宽度。
  Object _key(Size size) => (
    cell,
    options,
    theme,
    color,
    ruleColor,
    _inkBackdrop,
    links?.state.revision,
    size.width,
    paintImageBoxes,
  );

  bool prepare(Size size) =>
      pictures?.prepare(_key(size), (canvas) => _draw(canvas, size)) ?? false;

  @override
  void paint(Canvas canvas, Size size) {
    final cache = pictures;
    if (cache == null) {
      _draw(canvas, size);
    } else {
      cache.paint(canvas, _key(size), (target) => _draw(target, size));
    }
  }

  void _draw(Canvas canvas, Size size) {
    final trace = ReaderTurnDiagnostics.active;
    if (trace == null) {
      _drawContent(canvas, size);
      return;
    }
    final watch = Stopwatch()..start();
    _drawContent(canvas, size);
    final elapsed = watch.elapsedMicroseconds;
    // 只记录较慢的首次绘制，便于和同一帧的构建、光栅及上屏时间对照。
    if (elapsed >= 500) {
      trace.event('scroll.recordCell', [
        elapsed,
        cell.to - cell.from,
        cell.table.length,
        cell.measured.text.length,
      ]);
    }
  }

  void _drawContent(Canvas canvas, Size size) {
    if (cell.table.isNotEmpty) {
      paintBlockBackgrounds(
        canvas,
        cell.table,
        options,
        theme ?? ReadingTheme.paper,
        images: images,
        backgroundAreas: backgroundAreas,
        scrollCellHeight: cell.height,
        paintImageBoxes: paintImageBoxes,
        paintShadows: paintShadows,
      );
      paintTableFragments(
        canvas,
        cell.table,
        options,
        color,
        ruleColor,
        theme: theme,
        images: images,
        backdrop: backdrop,
        links: links,
      );
      return;
    }
    final block = cell.measured;
    final fragment = PageFragment(
      block: block,
      lineFrom: cell.from,
      lineTo: cell.to,
      y: cell.gap,
      height: cell.paintHeight,
    );
    // 所有正文统一交给分页共用的画法，不能因没有背景框就退回旧的整行绘制，
    // 否则公式备用注释、分段位置、居中和字距会在滚动模式里失效。
    final palette = theme ?? ReadingTheme.paper;
    paintBlockBackgrounds(
      canvas,
      [fragment],
      options,
      palette,
      images: images,
      backgroundAreas: backgroundAreas,
      scrollCellHeight: cell.height,
      paintImageBoxes: paintImageBoxes,
      paintShadows: paintShadows,
    );
    ReaderTextPainter(
      options,
      palette,
      paragraphs: paragraphs,
      images: images,
      links: links,
      backgroundColor: backdrop,
    ).paint(canvas, size, fragment);
  }

  @override
  bool shouldRepaint(ScrollTextPainter old) =>
      old.cell != cell ||
      old.color != color ||
      old.ruleColor != ruleColor ||
      old.paintShadows != paintShadows ||
      old._inkBackdrop != _inkBackdrop ||
      old.options != options ||
      old.theme != theme;
}
