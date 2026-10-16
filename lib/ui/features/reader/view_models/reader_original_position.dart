part of 'reader_session_view_model.dart';

/// 管理原书位置上报、版式切换落点和一次性跳转请求。
mixin _ReaderOriginalPosition on AsyncNotifier<ReaderSession> {
  String get bookId;
  LayoutOptions? get _options;
  ReadingPosition? get _listeningRestore;
  set _listeningRestore(ReadingPosition? value);
  Map<ReadingLayoutMode, Locator> get _restoreArrivals;
  Locator? get _originalExact;
  set _originalExact(Locator? value);
  Locator? get _originalReportExact;
  set _originalReportExact(Locator? value);
  double? get _exactOriginalFraction;
  set _exactOriginalFraction(double? value);
  ReadingLayoutMode get _mode;
  set _mode(ReadingLayoutMode value);
  Map<ReadingLayoutMode, ({Locator anchor, double fraction, String? signature})>
  get _modePositions;
  Map<ReadingLayoutMode, Locator> get _modeArrivals;
  bool get _awaitingModeArrival;
  set _awaitingModeArrival(bool value);
  String? get _pendingOriginalText;
  set _pendingOriginalText(String? value);
  double? get _pendingOriginalFraction;
  set _pendingOriginalFraction(double? value);
  String? get _pendingOriginalAnchorId;
  set _pendingOriginalAnchorId(String? value);
  String? get _pendingOriginalTitle;
  set _pendingOriginalTitle(String? value);
  int get _jumpToken;
  set _jumpToken(int value);
  int _originalChapterRequest = 0;
  Locator? get _pendingAnchor;
  ({int chapter, double fraction, Completer<void> done})? get _progressLanding;
  ({String chapterId, String? blockId, double progress, Completer<void> done})?
  get _tocLanding;

  Future<void> persist();
  void reportDisplayArrival(Locator anchor);
  bool _matchesTocLanding(
    ReaderSession session,
    String chapterId,
    String? blockId,
    double progress,
  );
  Future<void> goToLocator(
    Locator locator, {
    bool restoringListening = false,
    bool manual = true,
  });

  Locator? takeOriginalExactPosition() {
    final result = _originalExact;
    _originalExact = null;
    _originalReportExact = result;
    _exactOriginalFraction = null;
    return result;
  }

  void reportPositionFailure(Object error, StackTrace stack) {
    state = AsyncError(error, stack);
  }

  void _clearRestoredPosition() {
    _listeningRestore = null;
    _originalExact = null;
    _originalReportExact = null;
    _restoreArrivals.clear();
  }

  // 恢复后的页首只是显示位置；没有继续翻页前，保留听书的精确锚点。
  ReadingPosition? _restoredPosition(Locator anchor) {
    final restored = _listeningRestore;
    if (restored == null) return null;
    final arrival = _restoreArrivals[_mode];
    if (arrival != null && !arrival.samePosition(anchor)) {
      _clearRestoredPosition();
      return null;
    }
    _restoreArrivals[_mode] = anchor;
    return restored;
  }

  String? takeOriginalLandingText() {
    final text = _pendingOriginalText;
    _pendingOriginalText = null;
    return text;
  }

  /// 同一句话在两种版式里可能落在页中部。未翻页时往返使用各自落点，
  /// 不把每次取整后的新页首继续换算，避免来回切换不断向前退。
  Future<void> switchLayoutMode(ReadingLayoutMode mode) async {
    if (_mode == mode) return;
    final session = state.value;
    final anchor = session?.currentAnchor;
    if (session == null || anchor == null) {
      setLayoutMode(mode);
      return;
    }
    final arrival = _modeArrivals[_mode];
    if (arrival == null ||
        arrival.chapterId != anchor.chapterId ||
        arrival.blockId != anchor.blockId ||
        arrival.utf16Offset != anchor.utf16Offset) {
      _modePositions.clear();
    }
    _modePositions[_mode] = (
      anchor: anchor,
      fraction: session.chapterProgress,
      signature: _options?.layoutSignature,
    );
    final target = _modePositions[mode];
    final listening = _restoredPosition(anchor);
    setLayoutMode(mode);
    if (listening != null) {
      _restoreArrivals.remove(mode);
      if (mode.isOriginal) {
        _originalExact = listening.locator;
        _pendingOriginalFraction = 0;
        _pendingOriginalText = null;
      } else {
        await goToLocator(listening.locator, restoringListening: true);
      }
      return;
    }
    if (mode.isOriginal) {
      _awaitingModeArrival = true;
      _pendingOriginalFraction = target?.fraction ?? session.chapterProgress;
      _pendingOriginalText =
          target != null && target.signature == _options?.layoutSignature
          ? null
          : (target?.anchor ?? anchor).exact;
    } else {
      await goToLocator(target?.anchor ?? anchor, manual: false);
      if (_mode == mode && state.value?.currentAnchor != null) {
        _modeArrivals[mode] = state.value!.currentAnchor!;
      }
    }
  }

  /// 告诉会话当前用的是哪种排版模式（W7 的排版模式设置）。
  ///
  /// 切回简化模式时清掉上报来的位置，位置重新由排版结果给出——否则翻页后进度
  /// 会停在切换前那一页。
  void setLayoutMode(ReadingLayoutMode mode) {
    _mode = mode;
    final session = state.value;
    if (session == null || mode.isOriginal) return;
    if (session.originalAnchor == null) return;
    state = AsyncData(session.copyWith(clearOriginalPosition: true));
  }

  /// 原书模式下 WebView 分栏完成后要落到的章内比例（[chapterIndex] 这一章）。
  ///
  /// 优先用换章时记下的落点（0 = 章首、1 = 章末），用过即清；
  /// 没有记下的落点时按当前位置现算（见 [_fractionOfCurrentPosition]）——
  /// 「直接以原书模式打开一本书」以及分栏补测（图片就绪后重新量页数）走这一条，
  /// 两次都会落在同一个位置，不会把用户拉回章首。
  double? takeOriginalLandingFraction(int chapterIndex) {
    final pending = _pendingOriginalFraction;
    _pendingOriginalFraction = null;
    if (pending != null) return pending;
    return peekOriginalLandingFraction(chapterIndex);
  }

  /// 同上，但**不取走**落点：正文区在首次分栏前先问一次，让分栏直接落在这一页。
  ///
  /// 不这样做的话，文档会先按第 0 页露出来（这份 XHTML 的第一页是封面），
  /// 分栏完成后再跳到正确页——用户看到的就是「先闪一下封面」。
  double? peekOriginalLandingFraction(int chapterIndex) {
    // 换章时记下的落点（章首/章末）优先：它比「按当前位置现算」更准
    final pending = _pendingOriginalFraction;
    if (pending != null) return pending;
    final session = state.value;
    if (session == null || chapterIndex != session.chapterIndex) return null;
    return _fractionOfCurrentPosition(session);
  }

  /// 目录中的原始锚点只供本次换章落位使用。
  String? takeOriginalLandingAnchor() {
    final anchor = _pendingOriginalAnchorId;
    _pendingOriginalAnchorId = null;
    return anchor;
  }

  /// 本次换章要落的**标题**（目录条目名）；没有则返回 null。
  ///
  /// 落点优先按标题找：目录锚点常常挂在标题前面的容器上，按锚点落会停在前一页，
  /// 位置也回不到条目上——滑块下方的章名和「下一章」就停在上一章、再点不动。
  String? takeOriginalLandingTitle() {
    final title = _pendingOriginalTitle;
    _pendingOriginalTitle = null;
    return title;
  }

  /// 原书模式按比例跳转（目录的比例兜底、进度滑块）。
  ///
  /// 换章走 [switchChapterForOriginal] 并记住落点比例；同一章内就发一个
  /// [ReaderSession.originalJump] 请求，由正文区下发给宿主页——原书模式没有简化
  /// 排版可排，此入口用「第几章 + 章内比例」表达。
  /// 书签须走goToBookmark携带精确锚点，不能以文字比例代替版面位置。
  Future<bool> jumpToOriginalChapter(
    int index, {
    required double fraction,
  }) async {
    final session = state.value;
    if (session == null) return false;
    if (index < 0 || index >= session.chapters.length) return false;
    final clamped = fraction.clamp(0.0, 1.0);
    if (index == session.chapterIndex) {
      // 当前章内跳转也作废正在读取的跨章请求，防止旧请求稍后覆盖这次选择。
      ++_originalChapterRequest;
      // 同一章只是下发一次定位，代价很小，每次都执行（拖动手感才跟手）
      _requestOriginalJump(clamped);
      return true;
    }
    return switchChapterForOriginal(index, atEnd: false, fraction: clamped);
  }

  void _requestOriginalJump(
    double fraction, {
    String? anchorId,
    String? title,
  }) {
    _clearRestoredPosition();
    final session = state.value;
    if (session == null) return;
    state = AsyncData(
      session.copyWith(
        originalJump: (
          token: ++_jumpToken,
          fraction: fraction,
          anchorId: anchorId,
          title: title,
        ),
      ),
    );
  }

  /// Locator 在某一章里的比例（原书模式跳转用）；正文读不出来时返回 null。
  Future<double?> _fractionOfLocatorIn(int index, Locator locator) async {
    final session = state.value;
    if (session == null) return null;
    final chapter = session.chapters[index];
    final content = await _contentFor(chapter);
    if (content == null) return null;
    final fraction = fractionOfLocator(
      content: content,
      bookId: bookId,
      contentVersion: session.book.contentVersion,
      chapterId: chapter.id,
      locator: locator,
    );
    traceBookmark('locator-fraction', {
      'locator': bookmarkTraceLocator(locator),
      'chapter': index,
      'chapterLength': content.textLength,
      'fraction': fraction,
    });
    return fraction;
  }

  /// 读某章正文：会话里已经是这一章就直接用，否则从内容仓库读；失败返回 null。
  Future<ChapterContent?> _contentFor(Chapter chapter) async {
    final session = state.value;
    if (session == null) return null;
    if (session.content?.chapterId == chapter.id) return session.content;
    try {
      return await ref
          .read(chapterContentRepositoryProvider)
          .chapter(bookId, chapter);
    } on Object {
      return null;
    }
  }

  /// 原书模式下的换章（计划 3.4：章边界由 Dart 管）。
  ///
  /// 只切「当前章 + 落点比例」，**不做简化模式的排版**：原书模式的正文由 WebView
  /// 画，Dart 只要知道是哪一章、落在章内哪个比例；简化模式的排版等真的切回去时再做，
  /// 免得每次跨章都白排一遍。[atEnd] 为 true 表示落在新章末尾（章首往回翻进上一章）。
  ///
  /// 返回 false 表示没换（章节越界或这一章正文读不出来），调用方留在原处。
  Future<bool> switchChapterForOriginal(
    int index, {
    required bool atEnd,
    double? fraction,
  }) async {
    final request = ++_originalChapterRequest;
    final session = state.value;
    if (session == null) return false;
    if (index < 0 || index >= session.chapters.length) return false;
    if (index == session.chapterIndex) return false;
    _clearRestoredPosition();
    final chapter = session.chapters[index];
    final ChapterContent content;
    try {
      content = await ref
          .read(chapterContentRepositoryProvider)
          .chapter(bookId, chapter);
    } on Object {
      // 这一章正文读不出来：不换章，用户留在原处（换过去只会得到一个空页）
      return false;
    }
    // 等正文的这段时间里可能又换过一次章：结果过期就丢掉
    final latest = state.value;
    if (!ref.mounted || request != _originalChapterRequest ||
        latest == null || latest.chapters[index].id != chapter.id) {
      return false;
    }

    // 正文和目标比例同一次发布，避免先发布章首，再被另一请求覆盖。
    _pendingOriginalFraction = fraction ?? (atEnd ? 1 : 0);
    state = AsyncData(
      latest.copyWith(
        chapterIndex: index,
        content: content,
        pageIndex: 0,
        // 换章后旧位置上作废，等新章分栏完成再按落点回填
        clearOriginalPosition: true,
      ),
    );
    return true;
  }

  /// 现在读到哪（章内比例 0–1）。
  ///
  /// 1. 原书模式用上报来的比例；
  /// 2. 简化模式用排版页首的比例；
  /// 3. 都还没有（刚打开、还没排版）时用上次退出时存下的 `Locator` 折算。
  double _fractionOfCurrentPosition(ReaderSession session) {
    if (session.isOriginal || (session.layout != null && session.isReady)) {
      return session.chapterProgress;
    }
    final saved = _pendingAnchor;
    final content = session.content;
    final chapter = session.chapter;
    if (saved != null && content != null && content.chapterId == chapter.id) {
      return fractionOfLocator(
        content: content,
        bookId: bookId,
        contentVersion: session.book.contentVersion,
        chapterId: chapter.id,
        locator: saved,
      );
    }
    return 0;
  }

  /// 原书排版模式上报了位置：换算成 `Locator` 存下来，据此算进度并落库。
  ///
  /// 换算优先按页首文字在标准化正文里搜（[locatorForTextFragment]），
  /// 搜不到退章内比例（[locatorForFraction]）——两者都是纯函数，有单测保证。
  Future<void> reportOriginalPosition({
    required int chapterIndex,
    required double fraction,
    required String firstText,
    int? pageCount,
  }) async {
    final session = state.value;
    if (session == null) return;
    if (chapterIndex < 0 || chapterIndex >= session.chapters.length) return;
    final chapter = session.chapters[chapterIndex];

    // 正文已经在手上时同步取用：换章落点会连着两次上报（页首 + 锚点元素），
    // 中间插一次 await 会让它们交错，先到的页首反而最后落库
    final held = session.content;
    final content = (held != null && held.chapterId == chapter.id)
        ? held
        : await _contentFor(chapter);
    // 正文读不出来：保持上一次的位置，不把进度算错
    if (content == null) return;

    if (_originalReportExact != null &&
        _exactOriginalFraction != null &&
        (_exactOriginalFraction! - fraction).abs() > 1e-9) {
      _originalReportExact = null;
    }
    if (_originalReportExact != null) _exactOriginalFraction = fraction;
    final locator =
        _originalReportExact ??
        locatorForTextFragment(
          content: content,
          bookId: bookId,
          contentVersion: session.book.contentVersion,
          chapterId: chapter.id,
          fragment: firstText,
        ) ??
        locatorForFraction(
          content: content,
          bookId: bookId,
          contentVersion: session.book.contentVersion,
          chapterId: chapter.id,
          fraction: fraction,
        );
    if (locator == null) return;

    // 换算期间可能已经换书/换章（或用户切回了简化模式），过期结果直接丢掉。
    // 这里必须连「是不是还是当前章」一起判：换章瞬间旧章可能还有一次位置上报
    // 在路上（翻页后 240ms 才报），放它进来会把会话拉回上一章——
    // 用户看到的就是「拖过去了，画面又跳回原来那一页」。
    final latest = state.value;
    if (latest == null ||
        !_mode.isOriginal ||
        chapterIndex != latest.chapterIndex ||
        latest.chapters[chapterIndex].id != chapter.id) {
      return;
    }

    if (_awaitingModeArrival) {
      _awaitingModeArrival = false;
      _modeArrivals[ReadingLayoutMode.original] = locator;
    }
    state = AsyncData(
      latest.copyWith(
        chapterIndex: chapterIndex,
        content: content,
        originalAnchor: locator,
        originalFraction: fraction.clamp(0.0, 1.0),
      ),
    );
    traceBookmark('position-accepted', {
      'chapter': chapterIndex,
      'fraction': fraction,
      'pages': pageCount,
      'locator': bookmarkTraceLocator(locator),
      'retainedExact': _originalReportExact != null,
    });
    final tocLanding = _tocLanding;
    reportDisplayArrival(locator);
    final updated = state.value!;
    if (tocLanding != null &&
        !tocLanding.done.isCompleted &&
        _matchesTocLanding(
          updated,
          tocLanding.chapterId,
          tocLanding.blockId,
          tocLanding.progress,
        )) {
      tocLanding.done.complete();
    }
    unawaited(persist());
    final landing = _progressLanding;
    if (landing != null &&
        landing.chapter == chapterIndex &&
        pageCount != null) {
      final expected = (landing.fraction * pageCount + 1e-7).floor().clamp(
        0,
        pageCount - 1,
      );
      if ((fraction * pageCount).round() == expected &&
          !landing.done.isCompleted) {
        landing.done.complete();
      }
    }
  }

  /// 宿主跟随后只更新显示；听书的持久进度仍由播放事件写入。
  void reportSpeechPosition(Locator locator, double fraction) {
    final session = state.value;
    if (session == null || session.chapter.id != locator.chapterId) return;
    state = AsyncData(
      session.copyWith(originalAnchor: locator, originalFraction: fraction),
    );
  }
}
