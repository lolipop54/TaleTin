part of 'original_reader_area.dart';

/// 只处理宿主页事件；索引完成、目标落位和用户翻页分别确认。
extension _OriginalHostEvents on _OriginalReaderAreaState {
  void _onRawMessage(
    Map<String, Object?> raw, {
    required bool isNeighbor,
    required int ordinal,
  }) {
    final host = _hosts[ordinal];
    if (raw['bookmarkPages'] case final Map pages) {
      traceTurn(
        'bookmarks chapter=$ordinal page=${raw['page']} ids=${pages.values.join(',')}',
      );
      host?.bookmarkPages = {
        for (final entry in pages.entries)
          entry.key as String: (entry.value as num).toInt(),
      };
    }
    if (ordinal == widget.session.chapterIndex &&
        host != null &&
        (raw['type'] == 'paginated' ||
            raw['type'] == 'relocate' ||
            raw['type'] == 'pageTurn')) {
      final page = (raw['page'] as num?)?.toInt() ?? _page;
      ref.read(originalPageBookmarksProvider(widget.bookId).notifier).update(
        widget.session.chapters[ordinal].id,
        {
          for (final entry in host.bookmarkPages.entries)
            if (entry.value == page) entry.key,
        },
      );
    }
    if (raw['type'] == 'centerTap') {
      // 相邻章那一页不接管点击（它只是滑过来给你看的）
      if (!isNeighbor) widget.onCenterTap();
      return;
    }
    if (raw['type'] == 'preparing') {
      _hosts[ordinal]
        ?..pageCount = null
        ..knownPageCount = 0;
      final slot = _slotMounted(ordinal);
      if (slot != null) {
        slot.ready = false;
        slot.settledFraction = null;
      }
      return;
    }
    final event = widget.controller.handle(raw, chapterIndex: ordinal);
    if (event == null) return;
    _handleEvent(event, isNeighbor: isNeighbor);
  }

  Future<void> _handleEvent(
    OriginalHostEvent event, {
    required bool isNeighbor,
  }) async {
    // 回调可能跨过一帧换槽，以最新会话判定文档身份。
    isNeighbor = event.chapterIndex != widget.session.chapterIndex;
    // 字号、图片加载和字体到位可能触发重新分栏，旧截图随之失效。
    if (event is HostPaginated && mounted) {
      _hosts[event.chapterIndex]
        ?..pageCount = event.indexComplete ? event.pageCount : null
        ..knownPageCount = event.pageCount;
      _updateState(
        () => _captureVersions.update(
          event.chapterIndex,
          (v) => v + 1,
          ifAbsent: () => 1,
        ),
      );
    }
    if (event is HostIndexReady) {
      _hosts[event.chapterIndex]
        ?..pageCount = event.pageCount
        ..knownPageCount = event.pageCount;
      if (!isNeighbor && mounted) {
        _pageCount = event.pageCount;
        unawaited(_refreshEdge());
      } else if (isNeighbor) {
        await _prepareNeighborBoundary(event.chapterIndex);
      }
      return;
    }
    final notifier = ref.read(readerSessionProvider(widget.bookId).notifier);
    if (!_speech.visible && _speechTarget(_speechSnapshot) != null) return;
    // 相邻章的上报只用来确认「它分栏好了没有」，不参与本会话的位置与进度
    if (isNeighbor) {
      final slot = _slotMounted(event.chapterIndex);
      if (event is HostPaginated && slot != null && !slot.ready) {
        final waiting = _pageReady.remove(event.chapterIndex);
        if (waiting != null && !waiting.isCompleted) waiting.complete(true);
        final since = slot.since;
        gtDebugLog(
          '[gt] ${slot.label}第 ${event.chapterIndex + 1} 章已就绪'
          '${since == null ? '' : '（挂上后 '
                    '${DateTime.now().difference(since).inMilliseconds}ms）'}',
        );
        _updateState(() => slot.ready = true);
        if (_waitingNeighbor && _handoverTarget == event.chapterIndex) {
          _waitingNeighbor = false;
          _waitingNeighborGuard?.cancel();
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted || _handoverTarget != event.chapterIndex) return;
            final atStart = _handoverDirection < 0;
            _animateSlideTo(
              atStart ? _pageWidth : -_pageWidth,
              onDone: () => unawaited(
                _commitAnimatedHandover(event.chapterIndex, atEnd: atStart),
              ),
            );
          });
        }
      }
      if (event is HostError) gtDebugLog('[gt] 相邻章报错：${event.message}');
      return;
    }
    if (event.chapterIndex != widget.session.chapterIndex) return;
    if (event is HostRelocate || event is HostPageTurn) {
      _positionReportVersion++;
    }
    if (!_landing &&
        event is HostRelocate &&
        _speechTarget(_speechSnapshot) != null) {
      // 字号/图片变化只更新几何；页首不能覆盖当前听书显示位置。
      _page = event.page;
      _pageCount = event.pageCount;
      _speech.boundaryKey = null;
      _speech.key = null;
      _scheduleSpeech();
      return;
    }
    if (_landing && event is HostRelocate) {
      _landingPosition = event;
      return;
    }
    switch (event) {
      case HostPaginated(:final chapterIndex, :final pageCount):
        // 页序与边界都以 relocate 为准（分栏完成时会紧接着上报一次），
        // 这里只记页数，供「提前预载相邻章」判断
        _pageCount = pageCount;
        if (_paginatedChapter != chapterIndex && mounted) {
          _updateState(() {
            _paginatedChapter = chapterIndex;
            _everReady = true;
          });
        }
        // 新章可读：换章收尾（放守卫、落点定位、预取相邻章、重新问边界）
        unawaited(_finishChapterReadable(chapterIndex));
      case HostPageTurn(:final page, :final pageCount):
        // 翻页动画刚开始就到的轻量上报：只为「现在到没到章末」服务，
        // 位置与进度仍以稍后的 relocate 为准（那条要遍历元素算页首文字）
        _page = page;
        _pageCount = pageCount;
        // 页变了：上一页算出来的选区矩形已经不对，先收起来（S4）
        _dropSelectionOnPageChange(page);
        unawaited(_refreshEdge());
        _syncNeighbors();
      case HostRelocate(
        :final chapterIndex,
        :final page,
        :final pageCount,
        :final fraction,
        :final firstText,
        :final point,
        :final indexComplete,
      ):
        final reportVersion = _positionReportVersion;
        final reportNavigation = _navigation;
        final reportingHost = _host;
        _page = page;
        _pageCount = pageCount;
        _dropSelectionOnPageChange(page);
        // 每次位置上报都问一次边界：换章之后页序可能和上一章末页一样，
        // 按「页序变了才问」会漏掉（实测踩过）
        unawaited(_refreshEdge());
        // 同时把两侧相邻章对齐到「当前章 ± 1」（换章后页序一变就重新对一次）
        _syncNeighbors();
        // 扫描交接由真实 DOM 点一次提交，宿主页摘录不能先写入另一个位置。
        if (_scanKey.currentState?.phase == ScanPhase.committing) return;
        Locator? pageAnchor;
        if (point != null && ReaderDeliveryExperiments.contentTarget) {
          final navigation = _navigation;
          final session = widget.session;
          final map = await widget.controller.positionMap(
            chapterIndex,
            session.chapter.href ?? '',
            session.content!,
            session.currentAnchor ??
                ref
                    .read(readerSessionProvider(widget.bookId).notifier)
                    .peekOriginalExactPosition(chapterIndex) ??
                locatorForFraction(
                  content: session.content!,
                  bookId: widget.bookId,
                  contentVersion: session.book.contentVersion,
                  chapterId: session.chapter.id,
                  fraction: 0,
                )!,
          );
          if (!mounted ||
              navigation != _navigation ||
              chapterIndex != widget.session.chapterIndex) {
            return;
          }
          pageAnchor = OriginalSelectionMap(
            map: map,
            content: session.content!,
          ).locatorAt(point);
        }
        // 定位前宿主页还会按第 0 页报一次位置，那次会被紧接着的正确上报覆盖；
        // 两条上报都在同一章、正文已在会话里，因此不会有乱序问题
        if (ReaderDeliveryExperiments.originalWindow && reportingHost != null) {
          try {
            await reportingHost.presented();
          } on Object {
            // 页面退出/换章后平台视图可能已经释放；迟到回报没有保存资格。
            if (!mounted ||
                reportVersion != _positionReportVersion ||
                reportNavigation != _navigation ||
                reportingHost != _host) {
              return;
            }
            rethrow;
          }
        }
        if (!mounted ||
            reportVersion != _positionReportVersion ||
            reportNavigation != _navigation ||
            reportingHost != _host) {
          return;
        }
        await traceTurnStep(
          'position-convert chapter=$chapterIndex page=$page',
          () => notifier.reportOriginalPosition(
            chapterIndex: chapterIndex,
            fraction: fraction,
            firstText: firstText,
            pageCount: indexComplete ? pageCount : null,
            pageAnchor: pageAnchor,
          ),
        );
        notifier.reportOriginalContentArrival(
          ref.read(readerSessionProvider(widget.bookId)).value?.currentAnchor,
        );
      case HostReady(:final chapterIndex):
        // 文档就绪（框架脚本已执行）：高亮可以下发了，尽早发出去，
        // 让它和首次显示的正文一起出现（见 original_highlights.dart）
        if (_documentReadyChapter != chapterIndex && mounted) {
          _updateState(() => _documentReadyChapter = chapterIndex);
        }
      case HostBoundary(:final atStart, :final viaSettle):
        _onBoundary(atStart, viaSettle: viaSettle);
      case HostLink(:final href):
        _openLink(href);
      case HostError(:final message):
        AppErrors.report(
          StateError(message),
          StackTrace.current,
          operation: '原书页面执行失败',
        );
        gtDebugLog('[gt] 宿主页报错：$message');
      case HostIndexReady():
        break;
    }
  }

  /// 宿主页报了章边界（章末再往后 / 章首再往前）。
  ///
  /// 拖动撞出来的边界（[viaSettle]）如果那一侧的相邻章已经现成，就补上和拖动一样的
  /// 滑动交接——不然「甩得快」的时候边界是硬切出来的，看着就像下一页凭空冒出来。
  /// 点击撞出来的边界按老样子直接切，与简化模式一致。
}
