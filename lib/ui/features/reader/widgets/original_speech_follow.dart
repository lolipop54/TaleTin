part of 'original_reader_area.dart';

/// 状态只属于可见阅读页；后台控制器不引用 WebView。
class _SpeechFollowState {
  bool visible = true, queued = false, running = false, frameScheduled = false;
  bool covering = false, resuming = false;
  bool engaged = false;
  int version = 0;
  Object? key, boundaryKey;
  late ListeningService service;
  late AppLifecycleListener lifecycle;
}

extension _OriginalSpeechFollow on _OriginalReaderAreaState {
  ListeningState get _speechSnapshot => _speech.service.snapshot;
  Locator? _speechTarget(ListeningState state) =>
      state.bookId != widget.bookId || !state.hasSession || !state.followReading
      ? null
      : state.status == TtsStatus.paused
      ? state.resumeLocator
      : state.confirmedLocator;

  void _initSpeech() {
    _speech.service = ref.read(listeningServiceProvider);
    _speech.lifecycle = AppLifecycleListener(
      onStateChange: (state) {
        _speech.visible = state == AppLifecycleState.resumed;
        _speech.version++;
        _speech.key = null;
        if (!_speech.visible) {
          _speech.service.setPageBoundaries(this, const []);
          ref
              .read(readerSessionProvider(widget.bookId).notifier)
              .cancelSpeechFollow();
          // 隐藏期间不执行 JS；保留遮罩直到最新位置与高亮绘制就绪。
          if (_speechTarget(_speechSnapshot) != null) {
            _updateState(() => _speech.resuming = true);
          }
        } else {
          _speech.boundaryKey = null;
          _scheduleSpeech();
        }
      },
    );
  }

  void _scheduleSpeech() {
    final state = _speechSnapshot;
    // 普通阅读没有听书画面需要维护。邻章加载和落页不能取消手势或重定位。
    // 曾经跟随过听书时，停止/手动接管仍需完成最后一次高亮清理。
    if (_speechTarget(state) != null) _speech.engaged = true;
    if (!_speech.engaged) return;
    final key = (
      state,
      widget.settings,
      widget.theme,
      widget.session.chapterIndex,
      _captureVersions[widget.session.chapterIndex],
      _landing,
    );
    if (_speech.key == key || !_speech.visible) return;
    _speech.key = key;
    _speech.version++;
    _speech.queued = true;
    if (_speech.frameScheduled || _speech.running) return;
    _speech.frameScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _speech.frameScheduled = false;
      if (mounted) unawaited(_drainSpeech());
    });
  }

  bool _speechCurrent(int version, ListeningState state) =>
      mounted &&
      _speech.visible &&
      version == _speech.version &&
      identical(state, _speechSnapshot);

  Future<void> _drainSpeech() async {
    _speech.running = true;
    try {
      while (mounted && _speech.visible && _speech.queued) {
        _speech.queued = false;
        final state = _speechSnapshot, version = _speech.version;
        final target = _speechTarget(state);
        if (target != null && target.chapterId != widget.session.chapter.id) {
          if (!_landing && !_speech.covering) {
            await _prepareJumpCover();
            _speech.covering = true;
          }
          if (!_speechCurrent(version, state)) continue;
          await ref
              .read(readerSessionProvider(widget.bookId).notifier)
              .followSpeech(target);
          continue; // 新文档在 _applyLanding 完成定位和高亮后才显示。
        }
        final host = _host;
        if (host == null) continue;
        if (_landing) {
          if (host.pageCount != null) {
            _paginatedChapter = widget.session.chapterIndex;
            _everReady = true;
            await _finishChapterReadable(widget.session.chapterIndex);
          }
          continue;
        }
        await _curlKey.currentState?.settleForSpeech();
        if (!_speechCurrent(version, state)) continue;
        await _paintSpeech(host, state, version);
        if (_speechCurrent(version, state)) {
          _releaseSpeechCover();
          if (target == null) _speech.engaged = false;
        }
      }
    } catch (error, stack) {
      if (mounted && _speech.visible) {
        ref
            .read(readerSessionProvider(widget.bookId).notifier)
            .reportPositionFailure(error, stack);
      }
    } finally {
      _speech.running = false;
    }
  }

  Future<bool> _paintSpeech(
    OriginalHostController host,
    ListeningState state,
    int version,
  ) async {
    if (!_speechCurrent(version, state)) return false;
    final session = widget.session;
    final content = session.content;
    if (content == null) return false;
    final target = _speechTarget(state);
    final unit = state.hasSession && state.bookId == widget.bookId
        ? state.activeUnit
        : null;
    if (target == null) {
      // 清理过程中相邻页可能完成预加载，遍历快照避免列表变化。
      for (final entry in _hosts.values.toList()) {
        if (!_speechCurrent(version, state)) return false;
        await entry.clearTtsRange(version);
      }
    }
    if (!state.hasSession || state.bookId != widget.bookId || !state.followReading) return true;
    final anchor = target ?? state.resumeLocator ?? session.currentAnchor;
    if (anchor == null || anchor.chapterId != session.chapter.id) return false;
    final map = await widget.controller.positionMap(
      session.chapterIndex,
      session.chapter.href ?? '',
      content,
      anchor,
    );
    if (!_speechCurrent(version, state) || host != _host) return false;
    final boundaryKey = (
      host,
      widget.settings,
      _captureVersions[session.chapterIndex],
    );
    if (_speech.boundaryKey != boundaryKey) {
      final points = await host.ttsBoundaries(map.nodes);
      if (!_speechCurrent(version, state) || host != _host) return false;
      _speech.service.setPageBoundaries(
        this,
        points.map(map.locatorOf).toList(),
      );
      _speech.boundaryKey = boundaryKey;
    }
    if (target != null) {
      if (!await host.followTtsPoint(map.point(target))) {
        throw StateError('无法定位当前听书文字');
      }
      if (!_speechCurrent(version, state)) return false;
    }
    if (unit != null &&
        !unit.isChapterTitle &&
        unit.sentenceStart.chapterId == session.chapter.id) {
      if (!await host.setTtsRange({
        'from': map.point(unit.sentenceStart),
        'to': map.point(unit.sentenceEnd, end: true),
        'version': version,
        'color': hexOf(widget.theme.speechHighlight),
      })) {
        return false;
      }
    } else {
      await host.clearTtsRange(version);
    }
    await host.presented();
    if (!_speechCurrent(version, state) || host != _host) return false;
    if (target != null) {
      final fraction = await host.fractionForPage(await host.page);
      if (!_speechCurrent(version, state)) return false;
      ref
          .read(readerSessionProvider(widget.bookId).notifier)
          .reportSpeechPosition(target, fraction);
    }
    return true;
  }

  void _releaseSpeechCover() {
    final image = _speech.covering ? _jumpCover : null;
    _updateState(() {
      if (_speech.covering) _jumpCover = null;
      _speech.covering = false;
      _speech.resuming = false;
    });
    if (image != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => image.dispose());
    }
  }
}
