part of 'original_reader_area.dart';

/// 原书持久高亮（实现计划 S6）：把本章的笔记与高亮记录交给宿主页画在正文之上。
///
/// 每次都整份重发（章 + 标注有变化就发一次）：宿主页把方块画在**内容坐标**上，
/// 翻页、拖动、换章都由它自己跟着正文平移，Dart 不每帧算矩形。跨章的记录按本章
/// 裁开（前章取到章末、后章从章首起），与简化模式的矩形裁剪是同一条规则。
extension _OriginalHighlights on _OriginalReaderAreaState {
  /// 这一批标注的签名：章、条数、每条的位置与颜色。只要它没变就不用重发。
  String _highlightSignature(
    List<Annotation> annotations, {
    bool includeChapter = true,
  }) {
    final session = widget.session;
    final buffer = StringBuffer(
      '${includeChapter ? session.chapterIndex : ''}#${widget.theme.name}#${annotations.length}',
    );
    for (final annotation in annotations) {
      if (annotation.isBookmark || annotation.color == null) continue;
      final end = annotation.end;
      buffer.write(
        '|${annotation.id}@${annotation.start.chapterId}:${annotation.start.blockId}:'
        '${annotation.start.utf16Offset}-${end?.chapterId}:${end?.blockId}:${end?.utf16Offset}'
        ':${annotation.color!.code}:${annotation.body.trim().isNotEmpty}',
      );
    }
    return buffer.toString();
  }

  /// 三章各自准备高亮；没有相关标注时不读取正文或建立文字对照表。
  Future<void> _prepareChapterHighlights(
    int ordinal,
    OriginalHostController host,
  ) async {
    await ref.read(annotationsProvider(widget.bookId).future);
    if (!mounted || _hosts[ordinal] != host) return;
    await _pushChapterHighlights(
      ordinal,
      host,
      ref.read(readerHighlightsProvider(widget.bookId)),
    );
    await _prepareChapterBookmarks(ordinal, host);
  }

  Future<Locator> _visiblePageAnchor() async {
    // 等旧预取结束还不够：恢复后到页首查询返回之间不能再开始一次预览。
    // 书签、听书共用此入口，整个读取期间保护当前 DOM，结束后恢复后台准备。
    final owner = Object();
    _preload.hold(owner);
    try {
      await _curlKey.currentState?.settleForSpeech(invalidatePages: false);
      if (!mounted) throw StateError('阅读页已关闭');
      final session = widget.session, host = _host, navigation = _navigation;
      if (host == null || _landing || session.content == null) {
        throw StateError('书页尚未就绪');
      }
      // 与自动阅读落页共用本页几何查询，避开跨页段落的节点首字和摘录匹配。
      // 页首为图片时保留图片位置，听书服务会从其后的文字开始。
      final point = await host.scanPageAnchor();
      if (!mounted ||
          host != _host ||
          navigation != _navigation ||
          point == null) {
        throw StateError('无法读取当前页位置');
      }
      final map = await widget.controller.positionMap(
        session.chapterIndex,
        session.chapter.href!,
        session.content!,
        session.currentAnchor!,
      );
      if (!mounted || host != _host || navigation != _navigation) {
        throw StateError('书页已切换');
      }
      final locator = map.locatorOf(point.cast<String, dynamic>());
      traceBookmark('visible-anchor', {
        'chapter': session.chapterIndex,
        'page': _page,
        'pages': _pageCount,
        'navigation': navigation,
        'domPoint': point,
        'locator': bookmarkTraceLocator(locator),
      });
      return locator;
    } finally {
      _preload.release(owner);
    }
  }

  /// 书签只改页上的条带，不重新分栏；避免保存书签时撤图、重排造成闪烁。
  Future<void> _refreshBookmarks() async {
    final version = ++_bookmarkRefreshVersion, owner = Object();
    _preload.hold(owner);
    try {
      // 先还原正在预览的页面并清掉含旧条带的截图；整个交接期间不能再补旧图。
      await _curlKey.currentState?.settleForSpeech();
      if (!mounted || version != _bookmarkRefreshVersion) return;
      final current = widget.session.chapterIndex;
      final entries = _hosts.entries.toList()
        ..sort(
          (a, b) =>
              (a.key == current ? 0 : 1).compareTo(b.key == current ? 0 : 1),
        );
      for (final entry in entries) {
        if (!entry.value.hasReadableWindow) continue;
        await _prepareChapterBookmarks(
          entry.key,
          entry.value,
          refresh: version,
        );
        if (!mounted || version != _bookmarkRefreshVersion) return;
      }
      final host = _host;
      if (host == null) return;
      // setBookmarks 的 JS 返回只说明节点已更新；确认网页实际绘制后，
      // 才通知下拉层撤掉过渡条带，避免露出仍没有新条带的上一帧。
      await host.presented();
      if (!mounted || host != _host || version != _bookmarkRefreshVersion) {
        return;
      }
      ref.read(originalPageBookmarksProvider(widget.bookId).notifier).update(
        widget.session.chapter.id,
        {
          for (final entry in host.bookmarkPages.entries)
            if (entry.value == _page) entry.key,
        },
      );
      _updateState(() {
        for (final ordinal in _hosts.keys) {
          _captureVersions.update(ordinal, (v) => v + 1, ifAbsent: () => 1);
        }
      });
      // 新信息区进入 Flutter 画布后，后台截图才使用新条带状态。
      await WidgetsBinding.instance.endOfFrame;
    } finally {
      _preload.release(owner);
    }
  }

  Future<void> _prepareChapterBookmarks(
    int ordinal,
    OriginalHostController host, {
    int? refresh,
  }) async {
    final marks = await ref.read(bookmarksProvider(widget.bookId).future);
    if (!mounted || _hosts[ordinal] != host) return;
    final session = widget.session, chapter = widget.session.chapters[ordinal];
    final relevant = marks
        .where(
          (m) =>
              !m.locator.needsRelocation && m.locator.chapterId == chapter.id,
        )
        .toList();
    final points = <Map<String, Object?>>[];
    if (relevant.isNotEmpty) {
      final content = ordinal == session.chapterIndex && session.content != null
          ? session.content!
          : await ref
                .read(chapterContentRepositoryProvider)
                .chapter(widget.bookId, chapter);
      final map = await widget.controller.positionMap(
        ordinal,
        chapter.href!,
        content,
        relevant.first.locator,
      );
      for (final mark in relevant) {
        final point = map.displayPoint(mark.locator);
        traceBookmark('bookmark-dom', {
          'id': mark.id,
          'chapter': ordinal,
          'locator': bookmarkTraceLocator(mark.locator),
          'domPoint': point,
        });
        points.add({'id': mark.id, 'point': point});
      }
    }
    if (mounted &&
        _hosts[ordinal] == host &&
        (refresh == null || refresh == _bookmarkRefreshVersion)) {
      await host.setBookmarks(points);
    }
  }

  Future<void> _pushHighlights(List<Annotation> annotations) async {
    final host = _host;
    if (host != null) {
      await _pushChapterHighlights(
        widget.session.chapterIndex,
        host,
        annotations,
      );
    }
  }

  Future<void> _pushChapterHighlights(
    int ordinal,
    OriginalHostController host,
    List<Annotation> annotations,
  ) async {
    final session = widget.session;
    final chapter = session.chapters[ordinal];
    final version = ++_highlightVersion;
    _chapterHighlightVersions.removeWhere((h, _) => !_hosts.containsValue(h));
    _chapterHighlightVersions[host] = version;
    bool valid() =>
        mounted &&
        _hosts[ordinal] == host &&
        _chapterHighlightVersions[host] == version;
    final ordinals = chapterOrdinalsOf(session.chapters);
    final relevant = annotations.where((annotation) {
      if (annotation.isBookmark || annotation.color == null) return false;
      final first = ordinals[annotation.start.chapterId];
      final last = ordinals[(annotation.end ?? annotation.start).chapterId];
      return first != null &&
          last != null &&
          ordinal >= first &&
          ordinal <= last;
    }).toList();
    if (relevant.isEmpty) {
      await host.clearHighlights(version);
      traceTurn('chapter highlights ready chapter=$ordinal count=0');
      return;
    }
    final content = ordinal == session.chapterIndex && session.content != null
        ? session.content!
        : await ref
              .read(chapterContentRepositoryProvider)
              .chapter(widget.bookId, chapter);
    if (!valid()) return;
    final anchors = await widget.controller.positionMap(
      ordinal,
      chapter.href!,
      content,
      Locator(
        bookId: widget.bookId,
        contentVersion: session.book.contentVersion,
        chapterId: chapter.id,
        blockId: '',
        utf16Offset: 0,
      ),
    );
    if (!valid()) return;
    final map = OriginalSelectionMap(map: anchors, content: content);
    final items = <Map<String, Object?>>[];
    for (final annotation in relevant) {
      final end = annotation.end ?? annotation.start;
      final from = annotation.start.chapterId == chapter.id
          ? map.pointOf(annotation.start)
          : map.chapterEdgePoint(atEnd: false);
      final to = end.chapterId == chapter.id
          ? map.pointOf(end, end: true)
          : map.chapterEdgePoint(atEnd: true);
      if (from == null || to == null) continue;
      items.add({
        'id': annotation.id,
        'from': from,
        'to': to,
        'color': hexOf(highlightColorOf(annotation.color)),
        'hasThought':
            annotation.body.trim().isNotEmpty && end.chapterId == chapter.id,
        'thoughtColor': hexOf(readingLinkColor(widget.theme)),
      });
    }
    if (!valid()) return;
    await host.setHighlights(items, version);
    traceTurn(
      'chapter highlights ready chapter=$ordinal count=${items.length}',
    );
  }

  /// 点到已有高亮/笔记：选中它、开操作菜单（改颜色、编辑想法、删除）。
  ///
  /// 命中测试在宿主页做：它只认已经画出来的方块，「看得见」和「点得到」一致。
  /// 返回 true 表示这次点击已经处理，不再按分区翻页。
  Future<bool> _openHighlightAt(Offset local, {OriginalTapTarget? hit}) async {
    final host = _host;
    final session = widget.session;
    final content = session.content;
    final href = session.chapter.href;
    if (_landing || host == null || content == null || href == null) {
      return false;
    }
    // 仿真/覆盖入口已等待截图预取还原。命中检查只查询，不能重置当前手势，
    // 否则普通点击会在分区处理前失效，中心控制面板与两侧翻页都会被取消。
    final markers = hit != null ? hit.markers : await host.thoughtMarkers();
    if (!mounted || host != _host || _landing) return false;
    for (final marker in markers) {
      final rect = marker.rect.shift(_webViewOrigin);
      if (!rect.inflate(8).contains(local)) continue;
      final notes =
          ref.read(annotationsProvider(widget.bookId)).value ??
          const <Annotation>[];
      final note = notes.where((a) => a.id == marker.id).firstOrNull;
      if (note == null || note.body.trim().isEmpty) return true;
      if (!await _prepareManualTurn() || !mounted) return true;
      final box = context.findRenderObject()! as RenderBox;
      await showThoughtPopover(
        context,
        body: note.body,
        theme: widget.theme,
        anchor: rect.shift(box.localToGlobal(Offset.zero)),
      );
      return true;
    }
    final id = hit != null
        ? hit.highlight
        : await host.highlightAt(_toViewport(local));
    if (id == null || !mounted || host != _host) return false;
    final list = ref.read(annotationsProvider(widget.bookId)).value;
    if (list == null) return false;
    for (final annotation in list) {
      if (annotation.id != id) continue;
      final chapter = session.chapterIndex;
      final version = ++_selection.version;
      final map = await _selectionMapFor(chapter, href, content);
      if (map == null || !mounted || version != _selection.version) return true;
      final end = annotation.end ?? annotation.start;
      final geometry = await _selectionGeometry(
        map,
        annotation.start,
        end,
        paint: false,
      );
      if (geometry == null || !mounted || version != _selection.version) {
        return true;
      }
      ref
          .read(readerProvider.notifier)
          .startSelection(annotation.start, end, fromMark: true);
      _updateState(() {
        _selection
          ..chapter = chapter
          ..page = _page;
        _applyGeometry(geometry);
      });
      return true;
    }
    return false;
  }
}
