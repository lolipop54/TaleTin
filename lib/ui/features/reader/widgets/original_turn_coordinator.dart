part of 'original_reader_area.dart';

/// 协调一次原书翻页手势、动画交接、忙碌状态与最终提交。
extension _OriginalTurnCoordinator on _OriginalReaderAreaState {
  /// 把滑动位移补间到 [target]；固定200ms，沿用easeOutCubic。
  void _animateSlideTo(double target, {VoidCallback? onDone}) {
    if (widget.settings.pageTurnEffect != PageTurnEffect.slide) {
      _updateState(() => _slide = target);
      onDone?.call();
      return;
    }
    _slideTween = Tween<double>(
      begin: _slide,
      end: target,
    ).animate(CurvedAnimation(parent: _slideAnim, curve: Curves.easeOutCubic));
    _preload.hold('slide');
    _slideDone = onDone;
    _slideAnim.duration = readerTurnDuration;
    _slideAnim.forward(from: 0);
  }

  /// 这次拖动是不是「跨章滑动」：在章末继续往左、或在章首继续往右，
  /// 而且那一侧的相邻章已经预载好了。章内拖动交给宿主页平移（能看清下一页的边距）。
  bool _isBoundaryDrag(double dx) {
    if (!_isOutwardDrag(dx)) return false;
    final slot = _slotOf(dx);
    return slot.ordinal != null && slot.ready;
  }

  /// 这一拖是不是朝着章边界外（章末继续往左 / 章首继续往右）。
  ///
  /// 只看边界、不看相邻章排好没有：相邻章还没排好时同样不该把页面推出边界
  /// （那只会拖出一片空白），松手仍按最后明确方向判定换章（设计文档 2.4）。
  bool _isOutwardDrag(double dx) {
    // 单页章节同时是章首和章末，两个方向都应滑入相邻章节。
    if ((_edge == 'end' || _edge == 'both') && dx < 0) return true;
    if ((_edge == 'start' || _edge == 'both') && dx > 0) return true;
    return false;
  }

  /// 这一拖对应的相邻章槽：往左 = 看下一章（右侧槽）、往右 = 看上一章（左侧槽）
  _NeighborSlot _slotOf(double dx) => dx < 0 ? _next : _prev;

  Future<OriginalTurnTarget?> _resolveCurlTarget(
    bool backward, {
    bool silent = false,
  }) async {
    final host = _host;
    if (host == null) return null;
    final current = widget.session.chapterIndex;
    final navigation = _navigation;
    bool isCurrent() =>
        mounted &&
        _host == host &&
        widget.session.chapterIndex == current &&
        _navigation == navigation;
    await host.preparation;
    if (!isCurrent()) return null;
    final delta = backward ? -1 : 1;
    final page = await host.adjacentPage(delta);
    traceTurn('resolve adjacent chapter=$current delta=$delta page=$page');
    if (!isCurrent()) return null;
    if (page != null) {
      return _curlTarget(host, page, current);
    }
    final chapter = current + delta;
    if (chapter < 0 || chapter >= widget.session.chapters.length) {
      if (!silent) _notice(backward ? '已经是第一页了' : '已经是最后一页了');
      return null;
    }
    if (!silent) _preload.requestChapter(chapter);
    _syncNeighbors(requiredChapter: silent ? null : chapter);
    final slot = backward ? _prev : _next;
    traceTurn(
      'resolve neighbor chapter=$chapter ready=${slot.ready} silent=$silent',
    );
    if (silent && !slot.ready) return null;
    if (!slot.ready) {
      final ready = _pageReady.putIfAbsent(chapter, () => Completer<bool>());
      if (!await ready.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () => false,
      )) {
        _pageReady.remove(chapter);
        throw StateError('相邻章尚未就绪');
      }
      traceTurn('resolve neighbor ready chapter=$chapter');
    }
    if (!isCurrent()) return null;
    final target = _hosts[chapter];
    if (target == null) return null;
    await target.preparation;
    if (!isCurrent() || target.pageCount == null) return null;
    // 准备截图只查询目标页，不能提交位置；此时用户可能正在跳往这个文档。
    return _curlTarget(target, backward ? target.pageCount! - 1 : 0, chapter);
  }

  Future<OriginalTurnTarget> _curlTarget(
    OriginalHostController host,
    int page,
    int chapter,
  ) async {
    await host.prepareImagePage(page);
    final fraction = await host.fractionForPage(page);
    return (
      host: host,
      page: page,
      chapter: chapter,
      information: mounted
          ? readerInformation(
              context,
              ref,
              widget.session,
              widget.settings,
              widget.theme,
              chapter,
              fraction,
              showReturnProgress: false,
              bookmarked: host.bookmarkPages.containsValue(page),
            )
          : null,
    );
  }

  Future<bool> _commitCurl(OriginalTurnTarget target) async {
    if (target.chapter == widget.session.chapterIndex) {
      await target.host.commitPage(target.page);
      return true;
    }
    final handover = (
      chapter: target.chapter,
      page: target.page,
      ready: Completer<bool>(),
    );
    _curlHandover = handover;
    try {
      final moved = await _switchTo(
        target.chapter,
        atEnd: target.chapter < widget.session.chapterIndex,
      );
      // 会话换章不等于新 WebView 已绘制，截图必须覆盖到最终落页。
      return moved && await handover.ready.future;
    } finally {
      if (_curlHandover?.ready == handover.ready) _finishCurlHandover(false);
    }
  }

  /// 平移/无动画路径也按按下时的忙碌状态拒绝整轮输入，包含网页查询与落页等待。
  Future<void> _runPlainInput(Future<void> Function() action) async {
    if (_plainIgnorePointer || _plainBusy) return;
    final diagnostic = _turnLog;
    if (diagnostic != null) diagnostic.operationActive = true;
    diagnostic?.event('input.accept');
    _plainInputBusy = true;
    try {
      await measureReader(
        'original.${widget.settings.pageTurnEffect.name}.input',
        action,
      );
    } finally {
      _plainInputBusy = false;
      _finishTurnLog(diagnostic, 'inputReleased');
    }
  }

  Future<void> _waitPlainTurn() async {
    final diagnostic = _turnLog;
    diagnostic?.event('landing.wait.begin');
    if (widget.settings.pageTurnEffect == PageTurnEffect.slide) {
      await Future<void>.delayed(readerTurnDuration);
    }
    if (mounted) {
      diagnostic?.event('landing.android.begin');
      await measureReader(
        'original.${widget.settings.pageTurnEffect.name}.presented',
        () async => await _host?.pageTurnPresented(),
      );
      // 平台绘制完成后还要让 Flutter 消费新纹理；无动画也不能提前接收下一次输入。
      if (mounted) {
        diagnostic?.event('landing.android.end');
        await measureReader(
          'original.${widget.settings.pageTurnEffect.name}.flutterFrame',
          () => WidgetsBinding.instance.endOfFrame,
        );
      }
    }
    diagnostic?.event('landing.flutter.end');
  }

  /// 点击分区：左 35% 上一页、右 35% 下一页、中间 30% 控制栏。
  ///
  /// 分区与坐标一起交给宿主页，由它在同一次调用里判断「这一点是不是链接」——
  /// 书里的链接要交回 Dart 处理，而跨语言往返的次数直接影响点击手感。
  Future<void> _onTapUp(TapUpDetails details, double pageWidth) async {
    if (pageWidth <= 0) return;
    final auto = ref.read(automaticReadingProvider(widget.bookId).notifier);
    if (auto.consumePauseTap()) return;
    final center = (details.localPosition.dx - _webViewOrigin.dx) / pageWidth;
    if (auto.canResume &&
        center >= GtReadingTapZones.previousEdge &&
        center <= GtReadingTapZones.nextEdge) {
      widget.onCenterTap();
      return;
    }
    await auto.discard();
    if (!mounted) return;
    // 点到已有高亮/笔记：开它的操作菜单，不翻页（S6）
    final host = _host;
    if (host == null || _landing) return;
    final hit = await measureReader(
      'original.${widget.settings.pageTurnEffect.name}.hit',
      () => host.tapTarget(_toViewport(details.localPosition)),
    );
    if (!mounted || host != _host) return;
    if (await _openHighlightAt(details.localPosition, hit: hit) || !mounted) {
      return;
    }
    if (await _openImage(details.localPosition, hit: hit) || !mounted) return;
    final ratio = (details.localPosition.dx - _webViewOrigin.dx) / pageWidth;
    final zone = ratio < GtReadingTapZones.previousEdge
        ? 'prev'
        : (ratio > GtReadingTapZones.nextEdge ? 'next' : 'center');
    if (zone != 'center' && !await _prepareManualTurn()) return;
    if (!mounted) return;
    if (_handoverTarget != null || _slideAnim.isAnimating) return;
    final point = _toViewport(details.localPosition);
    await _host?.tap(
      point.dx,
      point.dy,
      zone,
      animationDurationMs: readerTurnDuration.inMilliseconds,
    );
    if (zone != 'center') await _waitPlainTurn();
  }

  Future<bool> _openImage(Offset point, {OriginalTapTarget? hit}) async {
    final host = _host;
    if (_landing || host == null) return false;
    final url = hit != null
        ? hit.image
        : await host.imageAt(_toViewport(point));
    if (url == null || !mounted || host != _host) return false;
    try {
      if (await tryReaderImageGallery(
        context,
        ref,
        widget.bookId,
        galleryResourcePath(url),
      )) {
        return true;
      }
      if (!mounted) return true;
      final bytes = await widget.controller.imageBytes(url);
      if (!mounted) return true;
      if (bytes == null) throw StateError('图片资源不存在');
      if (Uri.parse(url).path.toLowerCase().endsWith('.svg')) {
        await showReaderSvg(context, SvgBytesLoader(bytes));
      } else {
        await showReaderImage(context, MemoryImage(bytes));
      }
    } catch (_) {
      if (mounted) _notice('图片无法打开，请重试');
    }
    return true;
  }

  Future<bool> _prepareManualTurn() async {
    if (_timedTurning) return true;
    final diagnostic = _turnLog;
    diagnostic?.event('manual.prepare.begin');
    try {
      await ref
          .read(readerSessionProvider(widget.bookId).notifier)
          .beginManualReading();
      if (!mounted) return false;
      // 截图翻页的目标图在resolve／capture时已经等待图片解码。缓存命中时
      // 起手再查询前后页会唤醒静止WebView，并与首帧绘制争用原生绘制资源。
      // 无动画仍直接显示网页，继续提前准备它即将可见的邻页。
      if (OpeningExperiments.visibleImageDecode &&
          widget.settings.pageTurnEffect == PageTurnEffect.none) {
        final host = _hosts[widget.session.chapterIndex];
        if (host != null) {
          await Future.wait([
            if (_page > 0) host.prepareImagePage(_page - 1),
            if (_page + 1 < _pageCount) host.prepareImagePage(_page + 1),
          ]);
        }
      }
      // 听书状态真正变化时才清理；普通翻页不能强制重置刚开始的手势。
      _scheduleSpeech();
      return true;
    } catch (_) {
      if (mounted) _notice('阅读位置保存失败，请重试');
      return false;
    } finally {
      diagnostic?.event('manual.prepare.end');
    }
  }

  /// 水平拖动开始：累计位移清零
  void _onDragStart(double pageWidth) {
    _turnLog?.event('drag.start', [pageWidth, _plainBusy, _plainIgnorePointer]);
    if (_plainIgnorePointer || _plainBusy) return;
    _manualDrag = _prepareManualTurn();
    _dragOffset = 0;
    _dragDirection = 0;
    _dragTailTravel = 0;
    _dragReleaseDirection = 0;
    _hostDragged = false;
    _notReadyLogged = false;
    _dragHandoverTarget = _handoverTarget;
  }

  /// 拖动中：章内由宿主页跟手平移（能看清下一页长什么样，含边距）；
  /// 到了章边界就换成滑动整个画面——相邻章那一页跟着手指进来。
  void _onDragUpdate(DragUpdateDetails details) {
    _turnLog?.event('drag.update', [
      details.delta.dx,
      _dragOffset,
      _plainBusy,
      _plainIgnorePointer,
    ]);
    if (_plainIgnorePointer || _plainBusy) return;
    final delta = details.delta.dx;
    _dragOffset += delta;
    if (widget.settings.pageTurnEffect == PageTurnEffect.none) return;
    if (delta != 0) {
      if (_dragDirection == 0) _dragDirection = delta.sign;
      _dragTailTravel = _dragTailTravel.sign == delta.sign
          ? _dragTailTravel + delta
          : delta;
      // 起手确定本次要翻哪一页，明确拖回才取消；抬手微抖不改判。
      if (_dragReleaseDirection == 0 || _dragTailTravel.abs() >= kTouchSlop) {
        _dragReleaseDirection = _dragTailTravel.sign;
      }
    }
    // 拖过起点也不临时换成另一页，和共用翻页区域保持一致。
    final shift = _dragOffset * _dragDirection > 0 ? _dragOffset : 0.0;
    if (_handoverTarget != null || _dragHandoverTarget != null) return;
    if (_isBoundaryDrag(shift)) {
      _turnLog?.event('drag.crossChapter', [shift]);
      // 越界的部分才用来滑动：让相邻页跟手，最多滑一整页（再多就不跟了）
      _resetHostShift();
      final limit = _pageWidth;
      _slide = shift.clamp(-limit, limit);
      return;
    }
    if (_isOutwardDrag(shift)) {
      _turnLog?.event('drag.neighborNotReady', [shift]);
      // 在边界往外拖、但那一侧的相邻章还没排好：不推移画面（拖出一片空白比不推移
      // 更让人困惑），松手按最后明确方向决定换章，数据就绪后再交接。
      _logNotReady(_slotOf(shift), '拖动中');
      _resetHostShift();
      return;
    }
    _hostDragged = true;
    if (_slide != 0) _slide = 0;
    unawaited(_host?.drag(shift) ?? Future<void>.value());
  }

  /// 把宿主页的跟手位移归零。
  ///
  /// 一次拖动可能先是章内平移（宿主页），越界后才换成整块滑动（Flutter）——
  /// 不归零的话当前页会带着上一次的位移上台，看着就是半页错位。
  void _resetHostShift() {
    if (!_hostDragged) return;
    _hostDragged = false;
    unawaited(_host?.drag(0) ?? Future<void>.value());
  }

  /// 边界上要滑相邻章、但它还没排好：记一条日志（每次拖动只说一次）。
  /// 这条日志直接回答「提前量够不够」——三槽之后正常不该出现。
  void _logNotReady(_NeighborSlot slot, String when) {
    if (_notReadyLogged) return;
    _notReadyLogged = true;
    final since = slot.since;
    gtDebugLog(
      '[gt] $when：${slot.label}'
      '${slot.ordinal == null ? '没挂上' : '第 ${slot.ordinal! + 1} 章'}还没就绪'
      '${since == null ? '' : '（挂上后 '
                '${DateTime.now().difference(since).inMilliseconds}ms）'}，'
      '这次不做滑动',
    );
  }

  void _onDragCancel() {
    _finishTurnLog(_turnLog, 'gestureCancelled');
    if (_plainIgnorePointer) return;
    _manualDrag = null;
    _dragOffset = 0;
    _dragHandoverTarget = null;
    _resetHostShift();
    if (_handoverTarget == null && _slide != 0) _animateSlideTo(0);
  }

  /// 松手：章内与跨章都按最后明确方向判定，网页只执行结果。
  Future<void> _onDragEnd(DragEndDetails details) async {
    if (await _manualDrag == false || !mounted) return;
    _manualDrag = null;
    if (widget.settings.pageTurnEffect == PageTurnEffect.none) {
      final dx = _dragOffset;
      _dragOffset = 0;
      if (dx.abs() > _pageWidth / 4 ||
          (details.primaryVelocity ?? 0).abs() > 420) {
        await (dx < 0 ? _host?.next() : _host?.prev());
        await _waitPlainTurn();
      }
      return;
    }
    final commit =
        _dragDirection != 0 && _dragReleaseDirection == _dragDirection;
    final pageDelta = commit ? -_dragDirection.toInt() : 0;
    final dx = _dragOffset;
    _dragOffset = 0;
    _hostDragged = false;
    final dragTarget = _dragHandoverTarget;
    _dragHandoverTarget = null;
    if (_handoverTarget != null || dragTarget != null) return;
    if (!commit) {
      if (_slide != 0) _animateSlideTo(0);
      await _host?.settle(0);
      await _waitPlainTurn();
      return;
    }
    // 到了章末还继续往左 / 章首继续往右：这一拖是要换章的
    if (!_isOutwardDrag(_dragDirection)) {
      await _host?.settle(pageDelta);
      await _waitPlainTurn();
      return;
    }
    // 方向按这一拖的实际方向算（往左 = 要看下一章、往右 = 要看上一章）
    final wantNext = pageDelta > 0;
    final slot = _slotOf(_dragDirection);
    if (slot.ordinal == null) {
      // 全书首尾没有相邻页：先滑回去，再由原来的边界提示处理。
      gtDebugLog(
        '[gt] 松手：不换章'
        '（这一侧没有相邻章）edge=$_edge dx=${dx.round()}',
      );
      if (_slide != 0) _animateSlideTo(0);
      // 这一拖确实要换章、但旁边没有能拿出手的那一章：退回宿主页处理，
      // 它会报边界，由会话给出「已经是最后一页了」这类提示
      await _host?.settle(pageDelta);
      await _waitPlainTurn();
      return;
    }
    if (!slot.ready) {
      // 已判定换章，但画面未到位时先留在旧页；就绪后再滑入。
      _logNotReady(slot, '松手');
      _waitForNeighbor(atStart: !wantNext);
      return;
    }
    // 滑到底之后再把章切过去：换章时相邻章那一页正好在屏幕位置上，
    // 交接不闪（WebView 也会被复用，不重新加载）
    gtDebugLog(
      '[gt] 松手：滑动换到第 ${slot.ordinal! + 1} 章'
      '（现成，dx=${dx.round()} direction=$_dragReleaseDirection）',
    );
    _handoverTarget = slot.ordinal;
    _handoverDirection = wantNext ? 1 : -1;
    _animateSlideTo(
      wantNext ? -_pageWidth : _pageWidth,
      onDone: () =>
          unawaited(_commitAnimatedHandover(slot.ordinal!, atEnd: !wantNext)),
    );
  }

  Future<void> _commitAnimatedHandover(
    int target, {
    required bool atEnd,
  }) async {
    // 边界事件的守卫可能仍举着；这次是动画自己的提交，允许它完成。
    _endSwitching();
    if (await _switchTo(target, atEnd: atEnd)) return;
    if (!mounted || _handoverTarget != target) return;
    _handoverTarget = null;
    _animateSlideTo(0);
  }

  /// 一页的宽度（跨章滑动与判定的基准）
  double get _pageWidth => _submittedPageWidth;

  void _onBoundary(bool atStart, {required bool viaSettle}) {
    if (_handoverTarget != null) return;
    final slot = atStart ? _prev : _next;
    final target = slot.ordinal;
    if (target == null || !slot.ready) {
      _waitForNeighbor(atStart: atStart);
      return;
    }
    if (!viaSettle || _slide != 0) {
      gtDebugLog(
        '[gt] 宿主页报章${atStart ? '首' : '末'}边界：直接换章'
        '（${viaSettle ? '拖动撞出' : '点击撞出'}）',
      );
      unawaited(_switchBy(atStart ? -1 : 1));
      return;
    }
    gtDebugLog('[gt] 宿主页报章${atStart ? '首' : '末'}边界：补一次滑动交接');
    _handoverTarget = target;
    _handoverDirection = atStart ? -1 : 1;
    _animateSlideTo(
      atStart ? _pageWidth : -_pageWidth,
      onDone: () => unawaited(_commitAnimatedHandover(target, atEnd: atStart)),
    );
  }

  /// 未预载或尚未落到目标页时，保留旧页直到相邻章可直接滑入。
  void _waitForNeighbor({required bool atStart}) {
    final target = widget.session.chapterIndex + (atStart ? -1 : 1);
    if (target < 0 || target >= widget.session.chapters.length) {
      _notice(atStart ? '已经是第一页了' : '已经是最后一页了');
      return;
    }
    final slot = atStart ? _prev : _next;
    _preload.requestChapter(target);
    if (_hosts[target]?.hasReadableWindow == true &&
        _hosts[target]?.pageCount == null) {
      unawaited(_prepareNeighborBoundary(target));
    }
    if (slot.ordinal != target) {
      _mount(slot, target);
      _pruneHosts();
      _updateState(() {});
    }
    _handoverTarget = target;
    _handoverDirection = atStart ? -1 : 1;
    _waitingNeighbor = true;
    _waitingNeighborGuard?.cancel();
    _waitingNeighborGuard = Timer(const Duration(seconds: 5), () {
      if (!_waitingNeighbor || _handoverTarget != target) return;
      _waitingNeighbor = false;
      _handoverTarget = null;
      _notice('章节还没准备好，请再试一次');
    });
  }

  /// 章边界换章（计划 3.4）：往后进下一章第一页，往回进上一章最后一页。
  ///
  /// 到全书首尾给出与简化模式相同的反馈，不静默停住。
  Future<void> _switchBy(int delta) async {
    final session = widget.session;
    final target = session.chapterIndex + delta;
    if (target < 0 || target >= session.chapters.length) {
      _notice(delta < 0 ? '已经是第一页了' : '已经是最后一页了');
      return;
    }
    await _switchTo(target, atEnd: delta < 0);
  }

  Future<bool> _switchTo(int target, {required bool atEnd}) async {
    if (_switching) return false;
    _switching = true;
    // 换章后原书文档整篇换掉，选区矩形必然过时（S4）
    _dropSelectionOnChapterChange();
    // 兜底：新章万一没能分栏（加载失败等），别让边界事件一直被忽略
    _switchGuard?.cancel();
    _switchGuard = Timer(const Duration(seconds: 5), _endSwitching);
    final switched = await traceTurnStep(
      'session switch target=$target atEnd=$atEnd',
      () => ref
          .read(readerSessionProvider(widget.bookId).notifier)
          .switchChapterForOriginal(target, atEnd: atEnd),
    );
    if (!switched) {
      _endSwitching();
      gtDebugLog('[gt] 换章未生效：第 ${target + 1} 章');
    }
    return switched;
  }

  void _endSwitching() {
    _switchGuard?.cancel();
    _switchGuard = null;
    _switching = false;
  }

  /// 这一章挂在哪个相邻章槽上（按章序号找）；不是相邻章就返回 null
  _NeighborSlot? _slotMounted(int ordinal) {
    if (_prev.ordinal == ordinal) return _prev;
    if (_next.ordinal == ordinal) return _next;
    return null;
  }

  void _notice(String message) =>
      ref.read(readerProvider.notifier).showNotice(message);
}
