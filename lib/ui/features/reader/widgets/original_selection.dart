part of 'original_reader_area.dart';

/// 原书选区的界面状态（实现计划 S4、S5）。
///
/// 矩形只属于「某一章某一页」：宿主页按当前的视口（含页面平移）回传矩形，
/// 换章后旧坐标作废；同章翻页先按整页宽平移，再由宿主页复核，
/// 不能直接把旧视口坐标铺在新页上。
class _OriginalSelectionState {
  /// 当前选区矩形所属的章与页（null 表示没有选区）
  int? chapter;
  int? page;

  /// 本页那一段的选区矩形（阅读页坐标，已含 WebView 原点）；别页的不在这里
  List<Rect> rects = const [];
  bool hasOverlay = false;

  /// 按文字顺序的两端在本页的落点；页首/页末另保留相邻页的扩选落点。
  Offset? leading, trailing;

  /// 两端交叉后仍保留正在拖动的端点身份，只交换它们的文字侧位置。
  bool reversed = false;

  /// 下一页首的继续扩选落点（阅读页坐标），没有文字高亮也能抓取。
  Offset? continuationAnchor;
  Offset? previousContinuationAnchor;

  /// 同章翻页保留网页完整几何，立即更新新页上的触摸位置。
  OriginalSelectionGeometry? geometry;
  int geometryPage = 0;
  Offset? get startAnchor => reversed ? trailingAnchor : leadingAnchor;
  Offset? get endAnchor => reversed ? leadingAnchor : trailingAnchor;

  /// 继续扩选手柄要使用邻页那行字的高度，不能沿用原页的字号。
  double heightFor(bool atEnd) {
    final value = geometry;
    if (value == null) return 0;
    final trailingSide = atEnd != reversed;
    return (trailingSide
            ? ((rects.isEmpty || trailing == null) && continuationAnchor != null
                  ? value.continuationHeight
                  : value.trailingHeight)
            : ((rects.isEmpty || leading == null) &&
                      previousContinuationAnchor != null
                  ? value.previousContinuationHeight
                  : value.leadingHeight)) *
        scale;
  }

  /// 按文字顺序的前端；页首边界也可以在上一页末抓取。
  Offset? get leadingAnchor => rects.isEmpty
      ? previousContinuationAnchor
      : leading ?? previousContinuationAnchor;

  /// 按文字顺序的后端；页末边界也可以在下一页首抓取。
  Offset? get trailingAnchor =>
      rects.isEmpty ? continuationAnchor : trailing ?? continuationAnchor;

  /// 任务版本：换章、翻页、重新长按时让在飞的换算作废
  int version = 0;

  /// 宿主页视口宽 → 阅读页宽的换算系数（矩形与手势坐标都按它换）
  double scale = 1;

  /// 页角判定用的正文盒（阅读页坐标），不随本页最后一段的长短变化。
  Rect edgeBox = Rect.zero;

  /// 正在拖手柄：翻页扩选期间选区要留着，改由拖动流程接管页序变化
  bool dragging = false;

  /// 已消费的拖动也要保留落点，停住不移动时翻页后仍按这个位置定位。
  Offset? dragHandle;
  double dragHalfLine = 0;

  /// 一次只处理一个目标页：翻页期间忽略后续的页沿计时
  bool turning = false;

  /// 页沿停够时长的翻页倒计时（方向：1 下一页、-1 上一页）
  Timer? edgeTimer;
  int edgeDirection = 0;

  /// 正在等宿主页报新页序（拖动翻页扩选用）
  Completer<int>? pageTurn;

  /// 本段选区已经提示过「长按页首/页尾翻页」（同一条高亮只提示一次）
  bool edgeHintShown = false;

  bool get active =>
      rects.isNotEmpty ||
      continuationAnchor != null ||
      previousContinuationAnchor != null;
}

extension _OriginalSelection on _OriginalReaderAreaState {
  /// 全局指针事件：只要有手指抬起/取消，就当作这次手柄拖动结束。
  ///
  /// 原书正文是平台视图（WebView），手指抬起的事件可能被它拿走，手柄的
  /// onPanEnd/onPanCancel 就收不到——拖动态一直挂着，页沿计时一页页续下去。
  void _onGlobalPointer(PointerEvent event) {
    if (event is! PointerUpEvent && event is! PointerCancelEvent) return;
    if (!_selection.dragging && _selection.edgeTimer == null) return;
    _finishSelectionDrag();
  }

  /// 全局选区已经被别处收起（笔记面板里删除、返回键、点空白）时，本页的矩形、
  /// 页沿判定与提示跟着作废。
  ///
  /// 必须在 build 里同步清：宿主页画的持久高亮已经撤掉了，Flutter 这一层的临时
  /// 底色若留着，用户看到的就是「点了删除，高亮还在，翻页才消失」（真机反馈）。
  /// 这里只清内存状态、不动全局选区，也不调 setState（本来就在重建）。
  void _dropSelectionIfCleared(SelectionRange? selection, bool fromMark) {
    if (selection != null) {
      // 已保存高亮只清临时底色；刚量好的矩形仍用于摆放操作菜单。
      if (fromMark && _selection.hasOverlay) {
        unawaited(_hosts[_selection.chapter]?.clearSelection());
        _selection.hasOverlay = false;
      }
      return;
    }
    if (!_selection.hasOverlay && !_selection.active) return;
    unawaited(_hosts[_selection.chapter]?.clearSelection());
    _selection.hasOverlay = false;
    _selection.geometry = null;
    _selection.continuationAnchor = null;
    _selection.previousContinuationAnchor = null;
    _selection.leading = null;
    _selection.trailing = null;
    _selection.version++;
    _cancelSelectionEdge();
    _selection.dragging = false;
    _selection.edgeHintShown = false;
    _selection.rects = const [];
  }

  /// 长按起选：这一点所在的整句，取回矩形后画在正文上。
  ///
  /// 位置一律走「DOM 点 → 标准正文 Locator」这一条路：重复句、内联标签、
  /// 空白折叠都由对照表处理，不拿相同文字猜位置。任何一步拿不到就当作没选中，
  /// 不猜一个近似范围。
  Future<void> _beginSelection(Offset local) async {
    await ref.read(automaticReadingProvider(widget.bookId).notifier).discard();
    if (!mounted) return;
    final host = _host;
    final session = widget.session;
    final content = session.content;
    final href = session.chapter.href;
    if (_landing || host == null || content == null || href == null) return;
    final version = ++_selection.version;
    // 截图预取会暂时切到邻页。先等原页恢复，并废弃旧页序缓存，才能命中正文。
    await _curlKey.currentState?.settleForSpeech();
    if (!_selectionCurrent(version, host)) return;
    // 换章、翻页后在飞的换算不能落到新画面上：整段只在最后一起提交
    final chapter = session.chapterIndex;
    final point = await host.selectionPointAt(
      _toViewport(local),
      character: true,
    );
    if (!_selectionCurrent(version, host) || point == null) return;
    final map = await _selectionMapFor(chapter, href, content);
    if (!_selectionCurrent(version, host) || map == null) return;
    final sentence = map.sentenceAt(point);
    if (sentence == null) return;
    // 先量一次句子范围的矩形：跨页时按「本页那一段」的两端把范围夹回来，
    // 两端手柄才都落在本页、看得见也抓得到（与简化模式同一条规则）
    final first = await _selectionGeometry(
      map,
      sentence.start,
      sentence.end,
      paint: false,
    );
    if (!_selectionCurrent(version, host) || first == null) return;
    final range = _clampToPage(map, sentence, first);
    // 范围确定后才画一次，避免重建把尚未发布的临时选区当成已取消。
    final geometry = await _selectionGeometry(map, range.start, range.end);
    if (!_selectionCurrent(version, host) || geometry == null) return;
    ref.read(readerProvider.notifier).startSelection(range.start, range.end);
    _updateState(() {
      _selection
        ..chapter = chapter
        ..page = _page;
      _applyGeometry(geometry);
    });
  }

  /// 把长按选出的范围夹在本页内（与简化模式同一条规则）。
  ///
  /// 句子跨到上一页/下一页时，起点取本页那一段的第一个字、终点取最后一个字之后：
  /// 两端手柄都落在本页、看得见也抓得到，不用先翻页才能调。
  ///
  /// 两端直接取**这次量出来的矩形**边缘上的字（`pageFrom` / `pageTo`）：
  /// 页首常留空档，另去猜「页首第一个字在哪」会落到相邻页上（真机上踩过）。
  ({Locator start, Locator end}) _clampToPage(
    OriginalSelectionMap map,
    ({Locator start, Locator end}) range,
    OriginalSelectionGeometry geometry,
  ) {
    final fromPoint = geometry.pageFrom;
    final toPoint = geometry.pageTo;
    final pageStart = fromPoint == null ? null : map.pointLocatorAt(fromPoint);
    final pageLast = toPoint == null ? null : map.pointLocatorAt(toPoint);
    final pageEnd = pageLast == null ? null : map.nextChar(pageLast);
    var start = range.start;
    var end = range.end;
    // 只在本页边界之外才收：起点早于本页首字才前移，终点晚于本页末字才收回来
    if (pageStart != null && _earlier(start, pageStart)) start = pageStart;
    if (pageEnd != null && _earlier(pageEnd, end)) end = pageEnd;
    return (start: start, end: end);
  }

  /// 同一章内按阅读顺序比较：[a] 是否排在 [b] 前面
  bool _earlier(Locator a, Locator b) {
    final orderA = blockOrderOf(a.blockId);
    final orderB = blockOrderOf(b.blockId);
    if (orderA != orderB) return orderA < orderB;
    return a.utf16Offset < b.utf16Offset;
  }

  /// 收起选区：清掉矩形与全局选区，并让在飞的换算作废。
  void _clearSelection() {
    unawaited(_hosts[_selection.chapter]?.clearSelection());
    _selection.hasOverlay = false;
    _selection.geometry = null;
    _selection.continuationAnchor = null;
    _selection.previousContinuationAnchor = null;
    _selection.leading = null;
    _selection.trailing = null;
    _selection.version++;
    _cancelSelectionEdge();
    _selection.dragging = false;
    _selection.edgeHintShown = false;
    if (_selection.rects.isNotEmpty) {
      _updateState(() => _selection.rects = const []);
    }
    if (ref.read(readerProvider).selection != null) {
      ref.read(readerProvider.notifier).clearSelection();
    }
  }

  /// 页序变了：扩选由拖动流程接管，普通翻页保留范围、重算本页矩形。
  ///
  /// 拖动与「翻页交接」都算接管：松手和翻页是两条并行的时序，谁先到都可能，
  /// 交接还没完成就不能把选区收掉（真机上出现过松手早于上报、选区凭空消失）。
  /// **交接的判定要看 dragging/turning，不能看「本页还有没有矩形」**：拖动把
  /// 选区另一端留在别的页时，本页本来就没有矩形，漏掉交接会让翻页流程一直等，
  /// 端点不落地、手柄也就再也画不出来（真机反馈的「翻页后手柄不见、也拖不动」）。
  void _dropSelectionOnPageChange(int page) {
    if (_selection.page == page) return;
    _selection.page = page;
    if (_selection.dragging || _selection.turning) {
      // 新页的矩形按落点重新算：先不画，免得旧位置的矩形停在新页上
      _updateState(() => _selection.rects = const []);
      _completePageTurn(page);
      return;
    }
    if (ref.read(readerProvider).selection == null) return;
    final geometry = _selection.geometry;
    _updateState(() {
      if (geometry != null) {
        _applyGeometry(geometry.shifted(page - _selection.geometryPage));
      }
    });
    unawaited(_restoreSelectionOnPage());
  }

  /// 范围是正文位置，翻页只使旧坐标过时；回到原页仍显示原来的范围。
  Future<void> _restoreSelectionOnPage() async {
    final host = _host;
    final range = ref.read(readerProvider).selection;
    final session = widget.session;
    final content = session.content;
    final href = session.chapter.href;
    if (host == null || range == null || content == null || href == null) {
      return;
    }
    final version = ++_selection.version;
    await host.presented();
    await Future<void>.delayed(kSelectionTurnSettle);
    if (!_selectionCurrent(version, host)) return;
    final map = await _selectionMapFor(session.chapterIndex, href, content);
    if (map == null || !_selectionCurrent(version, host)) return;
    // 已有标注只重算菜单位置，不能再画临时底色及手柄后又撤掉。
    final geometry = await _selectionGeometry(
      map,
      range.start,
      range.end,
      paint: !ref.read(readerProvider).selectionFromMark,
    );
    if (geometry == null || !_selectionCurrent(version, host)) return;
    _updateState(() => _applyGeometry(geometry));
  }

  /// 换章后矩形必然过时（新文档的视口坐标不同）。
  void _dropSelectionOnChapterChange() {
    if (ref.read(readerProvider).selection == null) return;
    _clearSelection();
  }

  /// 在飞的换算还算数吗：同一章、同一宿主页、版本没被顶掉
  bool _selectionCurrent(int version, OriginalHostController host) =>
      mounted && version == _selection.version && host == _host;

  /// 正在等新页序时交回页序（拖动翻页扩选用）
  void _completePageTurn(int page) {
    final turn = _selection.pageTurn;
    if (turn == null || turn.isCompleted) return;
    turn.complete(page);
  }

  /// 这一章的 DOM 对照表（与听书定位共用一份缓存）
  Future<OriginalSelectionMap?> _selectionMapFor(
    int chapter,
    String href,
    ChapterContent content,
  ) async {
    final session = widget.session;
    if (chapter != session.chapterIndex) return null;
    try {
      final map = await widget.controller.positionMap(
        chapter,
        href,
        content,
        Locator(
          // 只用它带上下文：bookId、正文版本、章号；位置本身不参与查表
          bookId: widget.bookId,
          contentVersion: session.book.contentVersion,
          chapterId: session.chapter.id,
          blockId: '',
          utf16Offset: 0,
        ),
      );
      if (chapter != widget.session.chapterIndex) return null;
      return OriginalSelectionMap(map: map, content: content);
    } on Object catch (error) {
      gtDebugLog('[gt] 原书选区对照表无法建立：$error');
      return null;
    }
  }

  /// 选区两端 → 宿主页的矩形与正文区几何；任一端没有对应文字时返回 null。
  Future<OriginalSelectionGeometry?> _selectionGeometry(
    OriginalSelectionMap selection,
    Locator start,
    Locator end, {
    bool paint = true,
  }) async {
    final host = _host;
    if (host == null) return null;
    // 拖动可能把两端拖过界：先按阅读顺序排好，再交给宿主页取范围
    final ordered = normalizeRange(
      SelectionRange(start: start, end: end),
      chapterOrdinals: chapterOrdinalsOf(widget.session.chapters),
    );
    final chapter = widget.session.chapter.id;
    final from = ordered.start.chapterId == chapter
        ? selection.pointOf(ordered.start)
        : selection.chapterEdgePoint(atEnd: false);
    final to = ordered.end.chapterId == chapter
        ? selection.pointOf(ordered.end, end: true)
        : selection.chapterEdgePoint(atEnd: true);
    if (from == null || to == null) return null;
    final color = kSelectionHighlight;
    final geometry = await host.selectionRects(
      from,
      to,
      reversed: _earlier(end, start),
      handleColor: paint
          ? '#${ref.context.gtColors.actionPrimary.toARGB32().toRadixString(16).substring(2)}'
          : null,
      color: paint
          ? 'rgba(${(color.r * 255).round()},'
                '${(color.g * 255).round()},${(color.b * 255).round()},${color.a})'
          : null,
    );
    if (geometry == null || geometry.rects.isEmpty) return null;
    if (paint) _selection.hasOverlay = true;
    return geometry;
  }

  /// 把宿主页几何换算进阅读页坐标并存下来（矩形 + 换算系数 + 正文区）。
  ///
  /// 必须在 [setState] 里调用：矩形与正文区一起换，画出来的位置才对得上。
  void _applyGeometry(OriginalSelectionGeometry geometry) {
    final pageWidth = _submittedPageWidth;
    final scale = pageWidth <= 0 || geometry.width <= 0
        ? 1.0
        : pageWidth / geometry.width;
    final origin = _webViewOrigin;
    _selection.geometry = geometry;
    _selection.geometryPage = _page;
    Offset? onPage(Offset? point) =>
        point != null && point.dx >= 0 && point.dx < geometry.width
        ? origin + point * scale
        : null;
    _selection.continuationAnchor = onPage(geometry.continuation);
    _selection.previousContinuationAnchor = onPage(
      geometry.previousContinuation,
    );
    _selection.scale = scale;
    final range = ref.read(readerProvider).selection;
    _selection.reversed = range != null && _earlier(range.end, range.start);
    // 诊断：选区跨了哪些页、本页有几段（真机上核对跨页扩选用）
    gtDebugLog(
      '[gt] 选区几何 页${geometry.rects.first.page}..'
      '${geometry.rects.last.page} 本页${geometry.rects.where((r) => r.page == 0).length}段',
    );
    // 与简化模式一样按完整正文盒判定，末段较短时也必须拖到真正的页角。
    final top = origin.dy + geometry.content.top * scale;
    final bottom = top + geometry.content.height * scale;
    final settings = widget.settings;
    final margin =
        settings.horizontalPadding +
        (settings.spreadEnabled
            ? bookSpineWidth
            : settings.bookEdges
            ? bookEdgeWidth
            : 0);
    _selection.edgeBox = Rect.fromLTRB(
      origin.dx + margin,
      top,
      origin.dx + pageWidth - margin,
      bottom,
    );
    _selection.leading = onPage(geometry.leading);
    _selection.trailing = onPage(geometry.trailing);
    _selection.rects = [
      for (final item in geometry.rects)
        if (item.onPage)
          Rect.fromLTRB(
            origin.dx + item.rect.left * scale,
            origin.dy + item.rect.top * scale,
            origin.dx + item.rect.right * scale,
            origin.dy + item.rect.bottom * scale,
          ),
    ];
  }

  /// 阅读页坐标 → 宿主页视口坐标（CSS 像素）
  Offset _toViewport(Offset local) =>
      (local - _webViewOrigin) / (_selection.scale <= 0 ? 1 : _selection.scale);
}
