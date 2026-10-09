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
    _preload.hold('jump');
    _heldJumps++;
    try {
      await traceTurnStep('jump cover',
          () => _jumpCoverReady ??= _prepareJumpCover());
      if (mounted) {
        await traceTurnStep('jump request-and-position', jump);
        // 定位完成后菜单/高亮还会更新；等这一帧的宿主页绘制完成才揭开旧页。
        await WidgetsBinding.instance.endOfFrame;
        await _host?.preparation;
        await _host?.presented();
      }
    } finally {
      if (watch != null) gtDebugLog('[gt] 跳转完成 ${watch.elapsedMilliseconds}ms');
      if (--_heldJumps == 0) {
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
    final host = _host;
    if (host == null) return;
    final navigation = _navigation;
    final notifier = ref.read(readerSessionProvider(widget.bookId).notifier);
    final tocToken = notifier.originalTocPresentationToken;
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
    } else if (_curlHandover?.chapter == widget.session.chapterIndex && host.hasHeldPage) {
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
    await host.presented();
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
    }
    if (!mounted || navigation != _navigation || host != _host) return;
    _preload.release('landing');
    _preload.requestChapter(null);
    notifier.completeOriginalTocPresentation(tocToken, widget.session.chapterIndex);
    if (annotation != null) notifier.completeAnnotationLanding();
    _releaseSpeechCover();
    _speech.key = null;
    _scheduleSpeech();
    if (_curlHandover?.chapter == widget.session.chapterIndex) {
      _finishCurlHandover(true);
    }
  }

  /// 书内链接（计划 3.2）：同章跳锚点、跨章换章后再跳锚点，书外链接忽略。
  ///
  /// [href] 可能是相对路径（宿主页元素上原样取来的），也可能是绝对地址
  /// （WebView 导航回调给的），统一按当前章的文档地址解析。
  void _openLink(String href) async {
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
        final notifier = ref.read(readerSessionProvider(widget.bookId).notifier);
        await notifier.goToChapterFromToc(
          widget.session.chapters[target.ordinal].id,
          anchorId: target.fragment,
          rememberReturn: false,
        );
        await notifier.waitForTocPosition();
      });
    } catch (error) {
      if (mounted) _notice('书内链接定位失败，请重试');
      traceTurn('link landing failed type=${error.runtimeType}');
    }
  }
}
