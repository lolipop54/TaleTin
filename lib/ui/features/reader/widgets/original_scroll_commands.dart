part of 'original_scroll_area.dart';

/// 命令先准备附近章节和 DOM 对照表，宿主落位后才提交位置。
mixin _OriginalScrollCommands on ConsumerState<OriginalScrollArea> {
  InAppWebViewController? get host;
  bool get _loaded;
  int get _request;
  set _request(int value);
  Map<int, ({ChapterContent content, LocatorDomMap map})> get _maps;
  Map<int, String> get _preparing;
  ReaderSessionNotifier get _session;
  Future<void> _stopNativeScroll();
  int? _lastJump;
  int? _appliedJump;
  String? _requestedLayout, _preparedLayout;

  Future<Map<String, Object?>> _meta(int index) async {
    var entry = _maps[index];
    if (entry == null) {
      _preparing[index] = '正文';
      final chapter = widget.session.chapters[index];
      final content = await ref
          .read(chapterContentRepositoryProvider)
          .chapter(widget.bookId, chapter);
      final locator = LocatorMapper(
        bookId: widget.bookId,
        contentVersion: widget.session.book.contentVersion,
        chapterId: chapter.id,
      ).chapterStart(content.blocks);
      _preparing[index] = '原书位置映射';
      final map = await widget.original.positionMap(
        index,
        chapter.href!,
        content,
        locator,
      );
      _preparing.remove(index);
      if (!mounted) return {};
      entry = (content: content, map: map);
      _maps[index] = entry;
    }
    return {
      'index': index,
      'url': widget.original.source.chapterUrl(index).toString(),
      'nodes': entry.map.nodes,
      'imagePaths': entry.map.imagePaths,
    };
  }

  Map<String, Object?> _point(int index, Locator locator) {
    final entry = _maps[index]!;
    final images = entry.content.blocks
        .where((b) => b.kind == BlockKind.image)
        .toList();
    final image = images.indexWhere((b) => b.id == locator.blockId);
    return {
      'index': index,
      if (image >= 0) 'image': image,
      if (image < 0) ...entry.map.point(locator),
    };
  }

  Future<void> _open(
    Map<String, Object?> options,
    String layoutSignature,
  ) async {
    if (!_loaded || host == null) return;
    final request = ++_request;
    _requestedLayout = layoutSignature;
    final jump = widget.session.scrollJump;
    final anchor = _lastJump != jump?.token
        ? jump?.locator ?? _session.scrollOpeningAnchor
        : _session.scrollOpeningAnchor;
    _lastJump = jump?.token;
    final index = anchor == null
        ? widget.session.chapterIndex
        : widget.session.chapters.indexWhere((c) => c.id == anchor.chapterId);
    await _session.setScrolling(true);
    try {
      await _stopNativeScroll();
      // 附近章节已排好时只移动到对应文字，不重建三个 iframe。
      if (_preparedLayout == layoutSignature &&
          anchor != null &&
          _maps.containsKey(index)) {
        _appliedJump = jump?.token;
        final animated =
            jump != null && _session.speechScrollToken == jump.token;
        final moved = await host!.callAsyncJavaScript(
          functionBody:
              'gtScroll.request=$request;return await gtScroll.seek(${jsonEncode(_point(index, anchor))},$animated);',
        );
        if (moved?.value == true) return;
      }
      final metas = await Future.wait([
        for (
          var i = math.max(0, index - 1);
          i <= math.min(widget.session.chapters.length - 1, index + 1);
          i++
        )
          _meta(i),
      ]);
      if (!mounted || request != _request) return;
      _appliedJump = jump?.token;
      final point = anchor == null ? null : _point(index, anchor);
      options = {
        ...options,
        'fontCss': originalFontCss(options['fontFamily'] as String?),
      };
      await host!.evaluateJavascript(
        source:
            'gtScroll.request=$request;gtScroll.count=${widget.session.chapters.length};'
            'gtScroll.open(${jsonEncode(metas)},${jsonEncode(point)},${jsonEncode(options)})'
            '.catch(e=>{console.error("[scroll error] "+String(e)+"\\n"+e.stack);'
            'return window.flutter_inappwebview.callHandler("scrollHost",'
            '{type:"error",request:$request,message:String(e)});});',
      );
    } on Object catch (error) {
      if (mounted && request == _request) {
        ref.read(readerProvider.notifier).showNotice('原书准备失败：$error');
      }
    }
  }
}
