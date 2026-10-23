part of 'original_reader_area.dart';

/// 状态只属于可见阅读页；后台控制器不引用 WebView。
class _SpeechFollowState {
  bool visible = true, queued = false, running = false, frameScheduled = false;
  bool covering = false, resuming = false;
  bool engaged = false;
  int version = 0;
  String? stage;
  Object? key, boundaryKey;
  late ListeningService service;
  late AppLifecycleListener lifecycle;
  final diagnostics = ListeningFollowDiagnostics('original');
}

extension _OriginalSpeechFollow on _OriginalReaderAreaState {
  ListeningState get _speechSnapshot => _speech.service.snapshot;
  Locator? _speechTarget(ListeningState state) =>
      state.bookId == widget.bookId ? state.pageFollowLocator : null;

  Map<String, Object?> _speechDiagnosticSnapshot() => {
    ...listeningDiagnosticSnapshot(
      _speechSnapshot,
      readerBookId: widget.bookId,
      anchor: widget.session.currentAnchor,
    ),
    'visible': _speech.visible,
    'mounted': mounted,
    'running': _speech.running,
    'queued': _speech.queued,
    'frameScheduled': _speech.frameScheduled,
    'version': _speech.version,
    'stage': _speech.stage,
    'landing': _landing,
    'covering': _speech.covering,
    'resuming': _speech.resuming,
    'engaged': _speech.engaged,
    'hasHost': _host != null,
    'hasReadableWindow': _host?.hasReadableWindow,
    'chapter': widget.session.chapterIndex,
    'page': _page,
    'pages': _pageCount,
    'targetChapter': widget.session.chapters.indexWhere(
      (c) => c.id == _speechTarget(_speechSnapshot)?.chapterId,
    ),
  };

  void _speechLog(String event, [Map<String, Object?> details = const {}]) {
    if (_speech.diagnostics.observing) {
      _speech.diagnostics.step(event, {
        ..._speechDiagnosticSnapshot(),
        ...details,
      });
    }
  }

  /// 只包住原有等待并记录耗时，不加入重试、超时或新绘制请求。
  Future<T> _speechWait<T>(String stage, Future<T> Function() action) async {
    final clock = Stopwatch()..start();
    _speech.stage = stage;
    _speechLog('waitBegin');
    try {
      final result = await action();
      _speechLog('waitEnd', {
        'waitStage': stage,
        'waitMs': clock.elapsedMilliseconds,
        if (result is bool) 'result': result,
      });
      return result;
    } catch (error) {
      _speechLog('waitError', {
        'waitStage': stage,
        'type': error.runtimeType.toString(),
      });
      rethrow;
    } finally {
      if (_speech.stage == stage) _speech.stage = null;
    }
  }

  void _initSpeech() {
    _speech.service = ref.read(listeningServiceProvider);
    _speech.diagnostics.lifecycle('attached', _speechDiagnosticSnapshot());
    _speech.lifecycle = AppLifecycleListener(
      onStateChange: (state) {
        _speech.visible = state == AppLifecycleState.resumed;
        if (_speechSnapshot.bookId == widget.bookId) {
          _speech.diagnostics.lifecycle(
            state.name,
            _speechDiagnosticSnapshot(),
            snapshot: _speechDiagnosticSnapshot,
          );
        }
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
    if (_speechTarget(state) != null) {
      _speech.engaged = true;
    }
    if (!_speech.engaged) {
      _speechLog('scheduleSkip', {'reason': 'notEngaged'});
      return;
    }
    final key = (
      state,
      widget.settings,
      widget.theme,
      widget.session.chapterIndex,
      _captureVersions[widget.session.chapterIndex],
      _landing,
    );
    if (_speech.key == key || !_speech.visible) {
      _speechLog('scheduleSkip', {
        'reason': !_speech.visible ? 'background' : 'sameKey',
      });
      return;
    }
    _speech.key = key;
    _speech.version++;
    _speech.queued = true;
    if (_speech.frameScheduled || _speech.running) {
      _speechLog('scheduleSkip', {
        'reason': _speech.running ? 'drainRunning' : 'frameScheduled',
      });
      return;
    }
    _speech.frameScheduled = true;
    _speechLog('frameQueued');
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _speech.frameScheduled = false;
      _speechLog('frameCallback');
      if (mounted) unawaited(_drainSpeech());
    });
  }

  bool _speechCurrent(int version, ListeningState state) {
    final current =
        mounted &&
        _speech.visible &&
        version == _speech.version &&
        identical(state, _speechSnapshot);
    if (!current) {
      _speechLog('discard', {
        'requestVersion': version,
        'sameSnapshot': identical(state, _speechSnapshot),
      });
    }
    return current;
  }

  Future<void> _drainSpeech() async {
    _speech.running = true;
    _speechLog('drainBegin');
    try {
      while (mounted && _speech.visible && _speech.queued) {
        _speech.queued = false;
        final state = _speechSnapshot, version = _speech.version;
        final target = _speechTarget(state);
        _speechLog('check', {
          'status': state.status.name,
          'hasTarget': target != null,
          'chapter': widget.session.chapterIndex,
          'page': _page,
          'targetChapter': widget.session.chapters.indexWhere(
            (c) => c.id == target?.chapterId,
          ),
          'targetOffset': target?.utf16Offset,
          'landing': _landing,
        });
        if (target != null && target.chapterId != widget.session.chapter.id) {
          if (!_landing && !_speech.covering) {
            await _speechWait('prepareCover', _prepareJumpCover);
            _speech.covering = true;
          }
          if (!_speechCurrent(version, state)) continue;
          await _speechWait(
            'followChapter',
            () => ref
                .read(readerSessionProvider(widget.bookId).notifier)
                .followSpeech(target, diagnostics: _speech.diagnostics),
          );
          continue; // 新文档在 _applyLanding 完成定位和高亮后才显示。
        }
        final host = _host;
        if (host == null) {
          _speechLog('skip', {'reason': 'noHost'});
          continue;
        }
        if (_landing) {
          if (host.hasReadableWindow) {
            _paginatedChapter = widget.session.chapterIndex;
            _everReady = true;
            await _speechWait(
              'finishLanding',
              () => _finishChapterReadable(widget.session.chapterIndex),
            );
          }
          _speechLog('landingChecked');
          continue;
        }
        await _speechWait(
          'settleAnimation',
          () async => _curlKey.currentState?.settleForSpeech(),
        );
        if (!_speechCurrent(version, state)) continue;
        final painted = await _paintSpeech(host, state, version);
        if (painted && _speechCurrent(version, state)) {
          _releaseSpeechCover();
          if (target == null) _speech.engaged = false;
        }
      }
    } catch (error, stack) {
      _speechLog('drainError', {'type': error.runtimeType.toString()});
      if (mounted && _speech.visible) {
        ref
            .read(readerSessionProvider(widget.bookId).notifier)
            .reportPositionFailure(error, stack);
      }
    } finally {
      _speech.running = false;
      _speechLog('drainEnd');
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
    if (content == null) {
      _speechLog('skip', {'reason': 'noContent'});
      return false;
    }
    final target = _speechTarget(state);
    final unit = state.hasSession && state.bookId == widget.bookId
        ? state.activeUnit
        : null;
    if (unit == null) {
      // 清理过程中相邻页可能完成预加载，遍历快照避免列表变化。
      for (final entry in _hosts.values.toList()) {
        if (!_speechCurrent(version, state)) return false;
        await entry.clearTtsRange(version);
      }
    }
    if (target == null) {
      return true;
    }
    final anchor = target;
    if (anchor.chapterId != session.chapter.id) {
      _speechLog('skip', {'reason': 'differentChapter'});
      return false;
    }
    final map = await _speechWait(
      'positionMap',
      () => widget.controller.positionMap(
        session.chapterIndex,
        session.chapter.href ?? '',
        content,
        anchor,
      ),
    );
    if (!_speechCurrent(version, state) || host != _host) return false;
    final boundaryKey = (
      host,
      widget.settings,
      _captureVersions[session.chapterIndex],
    );
    if (_speech.boundaryKey != boundaryKey) {
      final points = await _speechWait(
        'ttsBoundaries',
        () => host.ttsBoundaries(map.nodes),
      );
      if (!_speechCurrent(version, state) || host != _host) return false;
      if (points == null) {
        _speechLog('skip', {'reason': 'boundariesMissing'});
        return false;
      }
      _speech.service.setPageBoundaries(
        this,
        points.map(map.locatorOf).toList(),
      );
      _speech.boundaryKey = boundaryKey;
    }
    if (!await _speechWait(
      'followTtsPoint',
      () => host.followTtsPoint(map.point(target)),
    )) {
      throw StateError('无法定位当前听书文字');
    }
    if (!_speechCurrent(version, state)) return false;
    if (unit != null &&
        !unit.isChapterTitle &&
        unit.sentenceStart.chapterId == session.chapter.id) {
      if (!await _speechWait(
        'highlight',
        () => host.setTtsRange({
          'from': map.point(unit.sentenceStart),
          'to': map.point(unit.sentenceEnd, end: true),
          'version': version,
          'color': hexOf(widget.theme.speechHighlight),
        }),
      )) {
        return false;
      }
    } else {
      await host.clearTtsRange(version);
    }
    await _speechWait('presented', host.presented);
    if (!_speechCurrent(version, state) || host != _host) return false;
    final fraction = await _speechWait(
      'pageFraction',
      () async => host.fractionForPage(await host.page),
    );
    if (!_speechCurrent(version, state)) return false;
    ref
        .read(readerSessionProvider(widget.bookId).notifier)
        .reportSpeechPosition(target, fraction);
    _speechLog('positioned', {
      'chapter': session.chapterIndex,
      'fraction': fraction,
      'visible': _speech.visible,
    });
    return true;
  }

  void _releaseSpeechCover() {
    _speechLog('releaseCover');
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
