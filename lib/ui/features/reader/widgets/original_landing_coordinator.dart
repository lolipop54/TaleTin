part of 'original_reader_area.dart';

/// 处理目录、进度与书内链接跳转，并保留旧画面直到目标落稳。
extension _OriginalLandingCoordinator on _OriginalReaderAreaState {
  Future<void> _prepareJumpCover() async {
    gtDebugLog(
      '[gt] 跳转遮盖准备 landing=$_landing chapter=${widget.session.chapterIndex}',
    );
    final host = _host;
    if (host == null || _landing) throw StateError('页面尚未就绪');
    final image =
        await (_curlKey.currentState?.captureVisiblePage() ?? host.capture());
    if (!mounted) {
      image.dispose();
      return;
    }
    _updateState(() => _jumpCover = image);
    // 先让当前页截图上屏，再允许同一 WebView 跳转或章节槽换位。
    await WidgetsBinding.instance.endOfFrame;
  }

  Future<void> _holdPageDuringJump(Future<void> Function() jump) async {
    final watch = const bool.fromEnvironment('GT_PROFILE_CAPTURE')
        ? (Stopwatch()..start())
        : null;
    // 连续点进度条共用当前页，最后一次跳转落稳后才撤掉，避免旧请求提前揭开。
    final request = ++_jumpCoverVersion;
    _preload.hold('jump');
    try {
      await traceTurnStep(
        'jump cover',
        () => _jumpCoverReady ??= _prepareJumpCover(),
      );
      if (mounted) {
        await traceTurnStep('jump request-and-position', jump);
        // 定位完成后菜单/高亮还会更新；等这一帧的宿主页绘制完成才揭开旧页。
        await traceTurnStep(
          'jump frame request=$request',
          () => WidgetsBinding.instance.endOfFrame,
        );
        await traceTurnStep(
          'jump preparation request=$request',
          () async => await _host?.preparation,
        );
        await traceTurnStep(
          'jump presented request=$request',
          () async => await _host?.presented(),
        );
      }
    } finally {
      if (watch != null) gtDebugLog('[gt] 跳转完成 ${watch.elapsedMilliseconds}ms');
      // 只由最新目标撤图。已被接管的请求不再持有遮盖，也不能迟到后撤掉新图。
      if (request == _jumpCoverVersion) {
        if (mounted) _preload.release('jump');
        _jumpCoverReady = null;
        if (mounted) {
          final image = _jumpCover;
          _updateState(() => _jumpCover = null);
          WidgetsBinding.instance.addPostFrameCallback((_) => image?.dispose());
        }
      }
    }
  }

  void _finishCurlHandover(bool ready) {
    final handover = _curlHandover;
    _curlHandover = null;
    if (handover != null && !handover.ready.isCompleted) {
      handover.ready.complete(ready);
    }
  }

  /// 章内定位请求（进度滑块、书签回到原文、同章目录定位）。
  ///
  /// 同一个位置连跳两次也要生效，所以按序号判断而不是按比例。
  void _consumeJumpRequest(ReaderSession session) {
    final jump = session.originalJump;
    if (jump == null || jump.token == _lastJumpToken) return;
    _lastJumpToken = jump.token;
    _finishCurlHandover(false);
    _navigation++;
    _landing = true;
    _preload.hold('landing');
    _landingPosition = null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          _lastJumpToken != jump.token ||
          widget.session.chapterIndex != session.chapterIndex) {
        return;
      }
      unawaited(
        _applyLanding(
          exact: ref
              .read(readerSessionProvider(widget.bookId).notifier)
              .takeOriginalExactPosition(),
          title: jump.title,
          anchorId: jump.anchorId,
          fraction: jump.fraction,
        ),
      );
    });
  }

  /// 把一次落点交给宿主页：目录原始锚点优先，标题和比例只负责兜底。
  Future<void> _applyLanding({
    Locator? exact,
    String? text,
    String? title,
    String? anchorId,
    double? fraction,
  }) async {
    final host = _host, navigation = _navigation;
    try {
      await _performLanding(
        exact: exact,
        text: text,
        title: title,
        anchorId: anchorId,
        fraction: fraction,
      );
    } catch (error, stack) {
      // 旧页面的失败没有资格终止新跳转；仅结束仍属于本次导航的等待。
      if (!mounted || host != _host || navigation != _navigation) return;
      _landingFlight = null;
      _endSwitching();
      _finishCurlHandover(false);
      _neighborReadiness.cancelAll();
      _preload.requestChapter(null);
      _preload.release('landing');
      AppErrors.report(error, stack, operation: '原书落页准备失败');
      // 不把尚未确认的画面当成落页成功；交给已有的阅读失败界面处理。
      ref
          .read(readerSessionProvider(widget.bookId).notifier)
          .reportPositionFailure(error, stack);
    }
  }

  Future<void> _performLanding({
    Locator? exact,
    String? text,
    String? title,
    String? anchorId,
    double? fraction,
  }) async {
    final host = _host;
    if (host == null) return;
    final navigation = _navigation;
    final notifier = ref.read(readerSessionProvider(widget.bookId).notifier);
    final tocToken = notifier.originalTocPresentationToken;
    traceBookmark('landing-begin', {
      'chapter': widget.session.chapterIndex,
      'navigation': navigation,
      'jumpToken': _lastJumpToken,
      'fraction': fraction,
      'exact': bookmarkTraceLocator(exact),
      'hasText': text?.isNotEmpty == true,
      'hasTitle': title?.isNotEmpty == true,
      'hasAnchorId': anchorId?.isNotEmpty == true,
      'page': _page,
      'pages': _pageCount,
      'fontSize': widget.settings.fontSize,
      'lineHeight': widget.settings.lineHeight,
      'paragraphGapEm': widget.settings.paragraphGapEm,
      'horizontalPadding': widget.settings.horizontalPadding,
      'fontWeight': widget.settings.fontWeight,
      'effect': widget.settings.pageTurnEffect.name,
    });
    if (!_speech.visible) {
      _landingFlight = null;
      return;
    }
    final speech = _speechSnapshot;
    final target = _speechTarget(speech);
    if (target != null) {
      try {
        if (target.chapterId != widget.session.chapter.id ||
            !await _paintSpeech(host, speech, _speech.version)) {
          _landingFlight = null;
          _speech.key = null;
          _scheduleSpeech();
          return;
        }
      } catch (error, stack) {
        if (mounted && _speech.visible && navigation == _navigation) {
          ref
              .read(readerSessionProvider(widget.bookId).notifier)
              .reportPositionFailure(error, stack);
        }
        return;
      }
    } else if (_curlHandover?.chapter == widget.session.chapterIndex &&
        host.hasHeldPage) {
      // 目标已由翻页流程定位并绘制，只提交位置，不再按比例定位一遍。
      await host.commitPage(_curlHandover!.page);
    } else if (exact != null) {
      final session = widget.session;
      try {
        final point = await widget.controller.resolvePosition(
          session.chapterIndex,
          session.chapter.href ?? '',
          session.content!,
          exact,
        );
        if (!mounted || navigation != _navigation || host != _host) return;
        if (!await host.goToDomPoint(point)) {
          throw StateError('原书中无法定位听书文字');
        }
      } catch (error, stack) {
        if (!mounted || navigation != _navigation) return;
        // 不以百分比猜测位置；交给既有阅读错误页展示失败原因。
        ref
            .read(readerSessionProvider(widget.bookId).notifier)
            .reportPositionFailure(error, stack);
        return;
      }
    } else {
      await host.goToTocTarget(
        text: text,
        anchorId: anchorId,
        title: title,
        fraction: fraction,
      );
    }
    final annotation = notifier.annotationTarget;
    if (annotation != null) {
      await _pushHighlights(ref.read(readerHighlightsProvider(widget.bookId)));
    }
    if (ReaderDeliveryExperiments.originalWindow) {
      await _prepareLandingNeighbors(host);
      if (!mounted || navigation != _navigation || host != _host) return;
    }
    await host.presented();
    traceBookmark('landing-presented', {
      'chapter': widget.session.chapterIndex,
      'navigation': navigation,
      'currentNavigation': _navigation,
      'sameHost': host == _host,
      'page': _landingPosition?.page,
      'pages': _landingPosition?.pageCount,
      'fraction': _landingPosition?.fraction,
      'bookmarkPages': host.bookmarkPages,
    });
    gtDebugLog(
      '[gt] 落页确认 chapter=${widget.session.chapterIndex} visible=${_speech.visible} relocate=${_landingPosition != null}',
    );
    if (!mounted || navigation != _navigation || host != _host) return;
    if (!_speech.visible ||
        (target != null && !identical(speech, _speechSnapshot))) {
      _landingFlight = null;
      _speech.key = null;
      _scheduleSpeech();
      return;
    }
    final position = _landingPosition;
    _landingPosition = null;
    _updateState(() {
      _landing = false;
      _landingFlight = null;
      _landedChapter = widget.session.chapterIndex;
    });
    if (target == null && position != null) {
      await _handleEvent(position, isNeighbor: false);
      notifier.reportOriginalContentArrival(exact);
    }
    if (!mounted || navigation != _navigation || host != _host) return;
    _preload.release('landing');
    _preload.requestChapter(null);
    notifier.completeOriginalTocPresentation(
      tocToken,
      widget.session.chapterIndex,
    );
    if (annotation != null) notifier.completeAnnotationLanding();
    _releaseSpeechCover();
    _speech.key = null;
    _scheduleSpeech();
    if (_curlHandover?.chapter == widget.session.chapterIndex) {
      _finishCurlHandover(true);
    }
  }

  /// 首屏的直接邻页若在另一资源，也必须准备好，不能把等待移给第一次翻页。
  Future<void> _prepareLandingNeighbors(OriginalHostController host) async {
    final current = widget.session.chapterIndex;
    final page = await host.page;
    final targets = [
      if (page == 0 && current > 0) current - 1,
      if (host.pageCount != null &&
          page == host.pageCount! - 1 &&
          current + 1 < widget.session.chapters.length)
        current + 1,
    ];
    for (final chapter in targets) {
      if (!mounted || host != _host || current != widget.session.chapterIndex) {
        return;
      }
      _preload.requestChapter(chapter);
      _syncNeighbors(requiredChapter: chapter);
      final slot = _slotMounted(chapter);
      if (slot?.ready == true) continue;
      if (!await _awaitNeighborReady(chapter, const Duration(seconds: 10))) {
        throw StateError('相邻章尚未就绪');
      }
    }
  }

  Future<bool> _awaitNeighborReady(int chapter, Duration timeout) async {
    try {
      return await _neighborReadiness.wait(chapter, timeout);
    } on TimeoutException {
      final host = _hosts[chapter], slot = _slotMounted(chapter);
      // 只在失败时记录内部状态，不记录书名、正文、文件路径或书籍编号。
      unawaited(
        AppErrors.store
            .append({
              'kind': 'originalNeighborTimeout',
              'time': DateTime.now().toIso8601String(),
              'chapter': chapter,
              'current': widget.session.chapterIndex,
              'navigation': _navigation,
              'mountedSlot': slot != null,
              'slotReady': slot?.ready,
              'hasHost': host != null,
              'stage': host?.preparationStage,
              'pages': host?.pageCount,
              'knownPages': host?.knownPageCount,
              'requestedChapter': _preload.requestedChapter,
              'backgroundBlocked': _preload.blocked,
            })
            .catchError((Object _) {}),
      );
      throw TimeoutException('相邻章节尚未准备好，请重试', timeout);
    }
  }

  /// 脚注引用：先弹气泡展示脚注内容，气泡里的“跳转”再走书内链接跳转。
  ///
  /// [localPoint] 是阅读区本地坐标；[viewportPoint] 是宿主页视口坐标（点击
  /// 由宿主页上报）。两者都用于把气泡尖角指到用户点的那个脚注标记上。
  Future<void> _openFootnote(
    String href, {
    Offset? localPoint,
    Offset? viewportPoint,
  }) async {
    final source = widget.controller.source;
    final target = source.resolveLink(
      source.chapterUrl(widget.session.chapterIndex),
      href,
    );
    if (target == null || target.fragment.isEmpty) {
      _notice('没有找到脚注内容');
      return;
    }
    try {
      final html = await source.chapterDocument(target.ordinal);
      final content = html == null
          ? (text: null, backLink: false)
          : footnoteContent(html, target.fragment);
      if (!mounted) return;
      if (content.backLink) {
        // 点的是注释里的“返回正文”链接：按普通书内跳转回原位置
        _openLink(href, rememberReturn: true);
        return;
      }
      if (content.text == null) {
        _notice('没有找到脚注内容');
        return;
      }
      final box = context.findRenderObject() as RenderBox?;
      final scale = _selection.scale <= 0 ? 1.0 : _selection.scale;
      final local =
          localPoint ??
          (viewportPoint == null
              ? null
              : viewportPoint * scale + _webViewOrigin);
      final center = local == null || box == null
          ? Offset(
              MediaQuery.sizeOf(context).width / 2,
              MediaQuery.sizeOf(context).height * 0.3,
            )
          : box.localToGlobal(local);
      await showFootnotePopover(
        context,
        anchor: Rect.fromCenter(center: center, width: 1, height: 1),
        theme: widget.theme,
        text: content.text!,
        // 从脚注跳过去也要能“返回原进度”，和目录跳转一致
        onJump: () => _openLink(href, rememberReturn: true),
      );
    } catch (error) {
      if (mounted) _notice('脚注读取失败，请重试');
    }
  }

  /// 书内链接（计划 3.2）：同章跳锚点、跨章换章后再跳锚点，书外链接忽略。
  ///
  /// [href] 可能是相对路径（宿主页元素上原样取来的），也可能是绝对地址
  /// （WebView 导航回调给的），统一按当前章的文档地址解析。
  void _openLink(String href, {bool rememberReturn = false}) async {
    final base = widget.controller.source.chapterUrl(
      widget.session.chapterIndex,
    );
    final target = widget.controller.source.resolveLink(base, href);
    if (target == null) {
      // 书外链接：不导航、不提示（书里写的外网地址永远发不出去）
      gtDebugLog('[gt] 书外链接忽略：$href');
      return;
    }
    if (_landing) return;
    try {
      await _holdPageDuringJump(() async {
        if (!mounted) return;
        final notifier = ref.read(
          readerSessionProvider(widget.bookId).notifier,
        );
        await notifier.goToChapterFromToc(
          widget.session.chapters[target.ordinal].id,
          anchorId: target.fragment,
          rememberReturn: rememberReturn,
        );
        await notifier.waitForTocPosition();
      });
    } catch (error) {
      if (mounted) _notice('书内链接定位失败，请重试');
      traceTurn('link landing failed type=${error.runtimeType}');
    }
  }
}
