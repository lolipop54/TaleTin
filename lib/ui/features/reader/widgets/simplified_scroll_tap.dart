part of 'simplified_scroll_area.dart';

mixin _SimplifiedScrollTap on ConsumerState<SimplifiedScrollArea> {
  ScrollWindow get _window;
  ScrollResources get _resources;
  ReaderSessionNotifier get _session;
  ScrollSelection? _selectionModel();

  Future<bool> _contentTap(Offset point) async {
    if (!_window.isReady || !_window.controller.hasClients) return true;
    var before = -_window.controller.offset;
    for (final entry in _window.entries) {
      final layout = entry.layout;
      if (point.dy >= before && point.dy < before + layout.height && layout.cells.isNotEmpty) {
        final i = layout.cellAt(point.dy - before), cell = layout.cells[i];
        final image = cell.table.where((f) => !f.frameOnly && f.imageSize != null &&
          Rect.fromLTWH(f.block.inset, before + layout.starts[i] + f.y,
            f.imageSize!.width, f.imageSize!.height).contains(point)).firstOrNull;
        final size = image?.imageSize ?? (cell.table.isEmpty ? cell.measured.imageSize : null);
        final path = image?.block.resourcePath ?? cell.block.resourcePath;
        final blockId = image?.block.blockId ?? cell.block.id;
        if (size != null && path != null && Rect.fromLTWH(
            image?.block.inset ?? (_window.options!.contentWidth - size.width) / 2,
            before + layout.starts[i] + (image?.y ?? cell.gap), size.width, size.height).contains(point)) {
          await _session.beginManualReading();
          if (!mounted) return true;
          final file = File(_resources.resolve(path));
          if (await tryReaderImageGallery(context, ref, widget.bookId, path,
            chapterId: layout.content.chapterId, blockId: blockId)) {
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
    if (!widget.session.book.format.usesOriginalWebView) return false;
    final locator = _selectionModel()?.hit(point, exact: true);
    if (locator == null) return false;
    final entry = _window.entries.firstWhere((e) => e.layout.content.chapterId == locator.chapterId);
    // 本次查询期间保留原文服务，读完关闭订阅；正常阅读不强制打开原书引擎。
    final subscription = ref.listenManual(originalLayoutProvider(widget.bookId), (_, _) {});
    try {
      final original = await ref.read(originalLayoutProvider(widget.bookId).future);
      final chapter = widget.session.chapters[entry.index];
      final map = await original.positionMap(entry.index, chapter.href!, entry.layout.content, locator);
      if (!mounted) return true;
      final href = map.linkAt(locator);
      if (href == null) return false;
      final target = original.source.resolveLink(original.source.chapterUrl(entry.index), href);
      if (target != null) {
        await _session.goToChapterFromToc(widget.session.chapters[target.ordinal].id,
            anchorId: target.fragment);
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
