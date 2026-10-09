part of 'original_reader_area.dart';

/// 管理原书模式的上一章、当前章、下一章三个宿主槽。
extension _OriginalNeighborSlots on _OriginalReaderAreaState {
  /// 问一次宿主页「现在在不在章首/章末」，据此准备相邻章。
  /// 页数可能比真实末页多一页（分栏会多算一个空列），所以这件事不能只看
  /// Dart 侧记的页序——不然到了真实的章末却挂不上相邻章，拖过去是空白。
  Future<void> _refreshEdge() async {
    final host = _host;
    if (host == null) return;
    final requestId = ++_edgeRequestId;
    final edge = await host.atEdge() ?? '';
    if (!mounted ||
        host != _host ||
        requestId != _edgeRequestId ||
        edge == _edge) {
      return;
    }
    _updateState(() => _edge = edge);
    _syncNeighbors();
  }

  /// 只在当前章已落稳且没有前台工作时补齐两侧；用户指定的目标章可以插队。
  void _syncNeighbors({int? requiredChapter}) {
    final current = widget.session.chapterIndex;
    if (_landing && requiredChapter == null) return;
    final count = widget.session.chapters.length;
    final wanted = requiredChapter ?? _preload.requestedChapter;
    var prevTarget = current > 0 ? current - 1 : null;
    var nextTarget = current + 1 < count ? current + 1 : null;
    if (_preload.blocked) {
      // 保留已加载的来路，不因暂缓远端而拆掉已有文档。
      if (_prev.ordinal != prevTarget && wanted != prevTarget) prevTarget = null;
      if (_next.ordinal != nextTarget && wanted != nextTarget) nextTarget = null;
    }
    if (_prev.ordinal == prevTarget && _next.ordinal == nextTarget) return;
    traceTurn('neighbor schedule current=$current prev=$prevTarget next=$nextTarget foreground=${_preload.blocked} requested=$wanted');
    _mount(_prev, prevTarget);
    _mount(_next, nextTarget);
    _pruneHosts();
    if (mounted) _updateState(() {});
  }

  void _resumeBackground() {
    if (_preload.blocked) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _preload.blocked) return;
      _deferredNeighborOrdinal = null;
      _syncNeighbors();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  /// 把某一侧的槽换成 [target] 章（null = 不挂）。
  /// 换掉的章节释放文档与命令入口；固定 iframe 留给新章节使用。
  void _mount(_NeighborSlot slot, int? target) {
    if (slot.ordinal == target) return;
    traceTurn('neighbor mount old=${slot.ordinal} target=$target current=${widget.session.chapterIndex} deferred=$_deferredNeighborOrdinal');
    gtDebugLog(
      '[gt] ${slot.label}改为第 ${target == null ? '（无）' : target + 1} 章：'
      '当前第 ${widget.session.chapterIndex + 1} 章第 ${_page + 1}/$_pageCount 页',
    );
    // 先不删命令入口：同一章可能正在这一轮里从左槽搬到右槽（或反过来）。
    // 两个槽都改完后由 [_pruneHosts] 一次清理，避免搬家途中误删仍在复用的章节控制器。
    slot
      ..ordinal = target
      ..ready = target != null && _hosts[target]?.pageCount != null
      ..settledFraction = null
      ..since = target == null ? null : DateTime.now();
  }

  void _pruneHosts() {
    final current = widget.session.chapterIndex;
    final previous = _prev.ordinal;
    final next = _next.ordinal;
    _hosts.removeWhere(
      (ordinal, _) =>
          ordinal != current && ordinal != previous && ordinal != next,
    );
  }

  /// 换章交接：新章如果就是预载好的相邻章，交接要「就地」或滑入，
  /// 不能让它凭空跳一下（章节文档按章序号复用，所以也不会重新加载）。
  ///
  /// - 拖动提交：相邻页已经被滑到屏幕位置上了，把位移归零就是连续的画面；
  /// - 目录跳转 / 上一章下一章按钮：它原本待在某一侧，让它从那一侧滑进来。
  ///
  /// 另外两件事必须在这里做，否则新章「没人收尾」：
  /// 1. 边界与页序全部作废（[_edge] 不知道新章在哪，宁可留空重问一次，
  ///    留着旧值会让「章末继续往外拖」判成章内拖动）；
  /// 2. 交接过来的那一章不会再上报一次 `paginated`（它早就分栏好了），
  ///    换章守卫、落点定位、相邻章这几件收尾工作得在这里补上（见
  ///    [_finishChapterReadable]）。
  void _syncHandover(double pageWidth) {
    final current = widget.session.chapterIndex;
    final previous = _lastCurrent;
    _lastCurrent = current;
    if (previous == null || previous == current) return;
    traceTurn('handover from=$previous to=$current prev=${_prev.ordinal}/${_prev.ready} next=${_next.ordinal}/${_next.ready}');
    // 自己提交的跨章翻页保留目标截图；外部跳转才废弃整个手势。
    if (_curlHandover?.chapter != current) {
      _finishCurlHandover(false);
      _navigation++;
    }
    _landing = true;
    _landingPosition = null;
    _landedChapter = null;

    final oldPrev = _prev.ordinal;
    final oldNext = _next.ordinal;
    final fromSide = oldNext == current ? 1 : (oldPrev == current ? -1 : 0);
    // 新章是预载好的相邻章（拖动提交、或目录/按钮跳到的正好是它）
    final handedOver = fromSide != 0;
    // 交接过来的那一章已经分栏好了（它刚才就在屏幕上或旁边待命）
    final handedReady =
        handedOver && (current == oldPrev ? _prev.ready : _next.ready);

    // 新章的边界与页序都要重新问（等它上报 relocate 时由 _refreshEdge 填上）
    _edge = '';
    _page = 0;
    _pageCount = 0;

    // 顺序跨章保留来路；远端只登记待补，真正交接结束后再开始加载。
    _preload.hold('landing');
    _deferredNeighborOrdinal = handedOver
        ? (current > previous ? current + 1 : current - 1) : null;
    final deferred = _deferredNeighborOrdinal;
    traceTurn('chapter handover target=$current readyHit=$handedReady deferred=$deferred');

    // 两侧重新对齐：刚离开的那一章正好是「往回拖」要看到的那一页
    // （章末往前拖时它在最后一页、章首往回拖时它在第一页），而且它刚刚还在屏幕上，
    // 一定已经分栏好了——章节文档按章序号复用（只是换了位置），不重新加载
    _remountKeepingReady(
      _prev,
      handedOver && current - 1 >= 0 && current - 1 != deferred
          ? current - 1
          : null,
      wasCurrent: previous,
    );
    _remountKeepingReady(
      _next,
      handedOver &&
              current + 1 < widget.session.chapters.length &&
              current + 1 != deferred
          ? current + 1
          : null,
      wasCurrent: previous,
    );
    _pruneHosts();

    // 刚离开的那一章现在待在哪个槽里：滑入动画期间画面上显示的就是它
    final held = _prev.ordinal == previous
        ? _prev
        : (_next.ordinal == previous ? _next : null);
    // 新章从哪一侧进来：交接过来的按它原来待的那一侧（右 +1 / 左 -1），
    // 直接挂上来的（相邻章此前没预载）按换章方向算
    final fromStart = handedOver ? fromSide < 0 : current < previous;
    _pendingEntrySlide = false;
    _entrySlideGuard?.cancel();
    _entrySlideGuard = null;
    _settleAfterSlide = null;

    if (_speechTarget(_speechSnapshot) != null ||
        _curlHandover?.chapter == current ||
        _jumpCover != null ||
        widget.settings.pageTurnEffect != PageTurnEffect.slide ||
        (handedOver && handedReady && _slide.abs() >= pageWidth * 0.9)) {
      // 拖动提交：相邻页已经滑到屏幕位置上了，直接归零即可（画面连续）
      _slide = 0;
      _slideTween = null;
      _settleNeighborSlots();
    } else if (held != null && held.ready) {
      // 按钮/目录跳转：刚离开的那一章还留在对面那一侧的槽里，先让它顶住画面，
      // 新章从它该来的一侧滑进来。
      // - 新章已经分栏好了（预载命中）：立刻滑入，画面上就是旧页换新页；
      // - 新章还在分栏：先停在这儿等它（见 [_finishChapterReadable]），
      //   否则滑进来的是一张还在排版的空白页——那正是用户看到的「闪一下」。
      _slide = fromStart ? -pageWidth : pageWidth;
      _slideTween = null;
      // 顶上画面的这一章正在滑出去，落位留到动画结束后再做
      _settleAfterSlide = held;
      if (handedReady) {
        _startEntranceSlide();
      } else {
        _pendingEntrySlide = true;
        _entrySlideGuard = Timer(const Duration(seconds: 5), () {
          // 兜底：新章一直没分栏（加载失败等）也不能让画面一直停着
          if (!mounted || !_pendingEntrySlide) return;
          _pendingEntrySlide = false;
          _startEntranceSlide();
        });
      }
    } else {
      // 目标章不是相邻章（目录/滑块跳到很远的章）：刚离开的那一章没留在两侧，
      // 没有能顶住画面的内容，等新章分栏完成后直接显示（与 W11 的口径一致）
      _slide = 0;
      _slideTween = null;
      _settleNeighborSlots();
    }

    if (!handedReady) return;
    // 交接过来的这一章不会再有 paginated 事件：收尾工作下一帧补上
    // （build 期间不能 setState，也不能在布局里下发 JS 命令）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_finishChapterReadable(current));
    });
  }

  /// 让两侧相邻章槽各自停在正确的一页：上一章那一侧停在它的最后一页、
  /// 下一章那一侧停在它的第一页。
  ///
  /// 为什么要主动纠正：章节文档按章序号复用，一章从「当前页」或另一侧槽挪过来时
  /// 不会再走一遍首次分栏，`initialFraction` 也就不再生效，页面会停在上一次读到的
  /// 位置。不纠正的话，往回翻会先闪一下它的章首页再跳到末页、往前翻会先闪一下
  /// 中间某一页再跳回首页（用户实测反馈）。
  void _settleNeighborSlots() {
    _settleSlot(_prev, 1);
    _settleSlot(_next, 0);
  }

  /// 单个槽的落位。[fraction] 1 = 末页、0 = 首页。
  ///
  /// 只对已经分栏好的槽下发；还没排好的由 `initialFraction` 在首次分栏时落位。
  /// 正在滑出屏幕的那个槽跳过（留到动画结束后再落位，免得用户看到它跳页）。
  void _settleSlot(_NeighborSlot slot, double fraction) {
    final ordinal = slot.ordinal;
    if (ordinal == null || !slot.ready) return;
    if (identical(slot, _settleAfterSlide)) return;
    if (slot.settledFraction == fraction) return;
    slot.settledFraction = fraction;
    gtDebugLog(
      '[gt] ${slot.label}槽落位：第 ${ordinal + 1} 章'
      '${fraction >= 1 ? '末页' : '首页'}',
    );
    unawaited(_hosts[ordinal]?.goToFraction(fraction) ?? Future<void>.value());
  }

  /// 换章滑入动画结束（或动画被打断时的时间兜底）后收尾：刚离开的那一章已经
  /// 滑出屏幕，这时再让它落位
  void _settleAfterEntranceSlide() {
    _entrySlideGuard?.cancel();
    _entrySlideGuard = null;
    _settleAfterSlide = null;
    _settleNeighborSlots();
  }

  /// 开始把新章滑进来，并在动画结束后让刚离开的那一章落位。
  ///
  /// 兜底计时器是给「动画被打断」准备的：动画的完成回调会被下一次
  /// [_animateSlideTo] 顶掉，落位不能只挂在它上面。
  void _startEntranceSlide() {
    _animateSlideTo(0, onDone: _settleAfterEntranceSlide);
    _entrySlideGuard?.cancel();
    _entrySlideGuard = Timer(
      const Duration(milliseconds: 400),
      _settleAfterEntranceSlide,
    );
  }

  /// 换章时把一侧的槽换到新目标；如果目标正好是**刚离开的那一章**
  /// （[wasCurrent]），那它刚刚还在屏幕上、必然已经分栏好了，直接标成就绪，
  /// 不再等一次永远不来的 `paginated`（等不到的话往回拖就没法滑）。
  void _remountKeepingReady(
    _NeighborSlot slot,
    int? target, {
    required int wasCurrent,
  }) {
    if (slot.ordinal != target) _mount(slot, target);
    if (target == wasCurrent && !slot.ready) {
      slot
        ..ready = true
        ..since = DateTime.now();
    }
  }

  /// 当前章分栏好了（可以读了）：放掉换章守卫、按落点定位、预取相邻章、
  /// 重新问一次边界。
  ///
  /// 两条路都会走到这里：新章是自己加载的（宿主页上报 `paginated`），
  /// 或者是从相邻章交接过来的（不会再上报，见 [_syncHandover]）。
  ///
  /// 换章守卫必须在这里放掉：它举着期间所有换章提交都会被丢掉。交接过来的章
  /// 不会上报 `paginated`，不在这里放掉的话守卫会一直举到 5 秒兜底定时器——
  /// 表现就是「换章之后往回拖/往前拖，第一次拖了没反应」（用户实测反馈）。
  Future<void> _finishChapterReadable(int chapterIndex) async {
    if (!mounted || chapterIndex != widget.session.chapterIndex) return;
    if (_landedChapter == chapterIndex || _landingFlight == _navigation) return;
    _landingFlight = _navigation;
    final notifier = ref.read(readerSessionProvider(widget.bookId).notifier);
    _endSwitching();
    // 分栏完成时宿主页停在第 0 页，位置由 Dart 说了算：
    // 记下的锚点优先（跨章书内链接），否则按会话位置定位一次
    final anchorId = notifier.takeOriginalLandingAnchor();
    final landingTitle = notifier.takeOriginalLandingTitle();
    // 落点比例无论用不用都要取走，免得它在下一次分栏补测时才生效
    final fraction = notifier.takeOriginalLandingFraction(chapterIndex);
    await _applyLanding(
      exact: notifier.takeOriginalExactPosition(),
      title: landingTitle,
      text: notifier.takeOriginalLandingText(),
      anchorId: anchorId,
      fraction: fraction,
    );
    if (!mounted || chapterIndex != widget.session.chapterIndex || _landing) {
      return;
    }
    // 目标落稳后才安排两侧；前台交接未结束时由共享忙碌状态继续暂缓。
    _syncNeighbors();
    // 落点定好之后新章才滑进来：换章期间画面一直停在旧章那一页，既不会闪空白，
    // 也不会先露出新章的错页再跳过去
    if (_pendingEntrySlide && chapterIndex == widget.session.chapterIndex) {
      _pendingEntrySlide = false;
      _startEntranceSlide();
    }
    unawaited(_refreshEdge());
    if (_handoverTarget != chapterIndex) return;
    _handoverTarget = null;
  }
}

/// 相邻章槽：上一章 / 下一章各一个，装的是哪一章、分栏好了没有。
///
/// 「就绪」是滑动推移的前提：没就绪时不做推移（拖出一片空白比不动更让人困惑），
/// 松手仍按位移与甩动判定换章。挂上的时刻用来记「提前量够不够」的诊断日志。
class _NeighborSlot {
  _NeighborSlot(this.label);

  /// 日志里怎么称呼它（上一章 / 下一章）
  final String label;

  /// 装着哪一章（spine 序）；null = 这一侧没挂（全书首尾）
  int? ordinal;

  /// 分栏完成了没有
  bool ready = false;

  /// 已经下发过的落位（1 = 末页、0 = 首页）：同一个槽同一个落位只下发一次
  double? settledFraction;

  /// 挂上的时刻（诊断用）
  DateTime? since;
}
