part of 'simplified_scroll_area.dart';

mixin _SimplifiedScrollTap on ConsumerState<SimplifiedScrollArea> {
  ScrollWindow get _window;
  ScrollResources get _resources;
  ReaderSessionNotifier get _session;
  ScrollSelection? _selectionModel();

  Future<bool> _contentTap(Offset point) async {
    if (!_window.isReady || !_window.controller.hasClients) return true;
    if (await _imageTap(point)) {
      return true;
    }
    return mounted ? _linkTap(point) : true;
  }

  Future<bool> _imageTap(Offset point) async {
    if (!mounted) return true;
    final viewImages =
        ref.read(readingControlsProvider).value?.imageViewing != false;
    var before = -_window.controller.offset;
    for (final entry in _window.entries) {
      final layout = entry.layout;
      if (point.dy >= before &&
          point.dy < before + layout.height &&
          layout.cells.isNotEmpty) {
        final i = layout.cellAt(point.dy - before), cell = layout.cells[i];
        // 表格和普通正文共用绘制时的图片矩形，公式也能放大查看。
        final local = point - Offset(0, before + layout.starts[i]);
        for (final visual in cell.positionedInlineImages) {
          if (!visual.rect.contains(local)) continue;
          if (await _imageNote(visual.image.noteLink, point)) return true;
          if (!mounted) return true;
          if (!viewImages) return false;
          await _session.beginManualReading();
          if (!mounted) return true;
          final image = visual.image, path = image.resourcePath;
          final file = File(_resources.resolve(path));
          if (path.toLowerCase().endsWith('.svg')) {
            await showReaderSvg(
              context,
              SvgFileLoader(file),
              formula: image.formula != null,
            );
          } else {
            await showReaderImage(context, FileImage(file));
          }
          return true;
        }
        final image = cell
            .positionedImages(_window.options!.contentWidth)
            .where((image) => image.rect.contains(local))
            .firstOrNull;
        final path = image?.block.resourcePath;
        if (image != null && path != null) {
          if (await _imageNote(image.block.noteLink, point)) return true;
          if (!mounted) return true;
          if (!viewImages) return false;
          final blockId = image.block.blockId;
          await _session.beginManualReading();
          if (!mounted) return true;
          final file = File(_resources.resolve(path));
          if (await tryReaderImageGallery(
            context,
            ref,
            widget.bookId,
            path,
            chapterId: layout.content.chapterId,
            blockId: blockId,
          )) {
            return true;
          }
          if (!mounted) return true;
          if (path.toLowerCase().endsWith('.svg')) {
            await showReaderSvg(context, SvgFileLoader(file));
          } else {
            await showReaderImage(context, FileImage(file));
          }
          return true;
        }
      }
      before += layout.height;
    }
    return false;
  }

  Future<bool> _imageNote(String? link, Offset point) {
    if (!mounted) return Future.value(true);
    return openReaderImageNote(
      context,
      ref: ref,
      bookId: widget.bookId,
      chapters: widget.session.chapters,
      link: link,
      point: point,
      theme: widget.settings.theme,
    );
  }

  Future<bool> _linkTap(Offset point) async {
    if (!widget.session.book.format.usesOriginalWebView) return false;
    final selection = _selectionModel();
    if (selection == null) return false;
    final link = readerLinkAtScrollPoint(selection, point);
    if (link != null) {
      if (!mounted) return true;
      final box = context.findRenderObject()! as RenderBox;
      final shown = await openReaderLink(
        context,
        ref: ref,
        bookId: widget.bookId,
        chapters: widget.session.chapters,
        link: link.link,
        footnote: link.footnote,
        anchor: box.localToGlobal(point),
        theme: widget.settings.theme,
      );
      if (!shown && mounted) {
        ref
            .read(readerProvider.notifier)
            .showNotice(link.footnote ? '没有找到脚注内容' : '书内链接读取失败，请重试');
      }
      return true;
    }
    final locator = selection.hit(point, exact: true);
    if (locator == null) return false;
    final entry = _window.entries.firstWhere(
      (e) => e.layout.content.chapterId == locator.chapterId,
    );
    final cell = entry.layout.cells
        .where(
          (c) =>
              c.block.id == locator.blockId &&
              locator.utf16Offset >= c.offset &&
              locator.utf16Offset <=
                  c.offset +
                      c.measured.text.length -
                      c.measured.displayPrefixLength,
        )
        .firstOrNull;
    // 邻近光标可能吸附到标记边缘，但未命中标记时不能跳到脚注正文。
    if (cell != null &&
        linkAtMeasured(
              cell.measured,
              locator.utf16Offset - cell.offset,
            )?.footnote ==
            true) {
      return false;
    }
    // 本次查询期间保留原文服务，读完关闭订阅；正常阅读不强制打开原书引擎。
    final subscription = ref.listenManual(
      originalLayoutProvider(widget.bookId),
      (_, _) {},
    );
    try {
      final original = await ref.read(
        originalLayoutProvider(widget.bookId).future,
      );
      final chapter = widget.session.chapters[entry.index];
      final map = await original.positionMap(
        entry.index,
        chapter.href!,
        entry.layout.content,
        locator,
      );
      if (!mounted) return true;
      final href = map.linkAt(locator);
      if (href == null) return false;
      final target = original.source.resolveLink(
        original.source.chapterUrl(entry.index),
        href,
      );
      if (target != null) {
        await _session.goToChapterFromToc(
          widget.session.chapters[target.ordinal].id,
          anchorId: target.fragment,
        );
      }
      return true;
    } on Object {
      if (mounted) ref.read(readerProvider.notifier).showNotice('书内链接读取失败，请重试');
      return true;
    } finally {
      subscription.close();
    }
  }
}
