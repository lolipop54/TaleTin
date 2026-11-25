part of '../views/reader_view.dart';

extension _SpreadPreparation on _ReaderSpreadAreaState {
  // 用户松手、方向和落页都已确定。利用收尾时间找下一对原文页；
  // 图片解码和整页栅格仍由落页后的准备流程负责。
  void _prepareAhead(PageTurnDirection direction) {
    _discardAhead();
    final origin = _target;
    if (origin == null) return;
    _aheadOrigin = origin;
    final forward = _aheadForward = direction == PageTurnDirection.forward;
    _ahead = Future<_SpreadPair?>.delayed(Duration.zero, () async {
      if (!mounted || _aheadOrigin != origin) return null;
      try {
        return await _resolve(forward, from: origin);
      } on LayoutCancelled {
        return null;
      } catch (error) {
        // 只丢弃预读结果。真正翻到此处时由正常读取流程重试并处理错误。
        traceTurn('spread lookahead discarded: ${error.runtimeType}');
        return null;
      }
    });
  }

  Future<_SpreadPair?>? _takeAhead(bool forward) {
    if (_aheadOrigin != _pair || _aheadForward != forward) {
      _discardAhead();
      return null;
    }
    final job = _ahead;
    _aheadOrigin = null;
    _ahead = null;
    return job;
  }

  void _discardAhead() {
    unawaited(_ahead?.then((pair) => pair?.releaseLayouts()));
    _ahead = null;
    _aheadOrigin = null;
  }

  Future<bool> _prepareTarget(PageTurnDirection direction) {
    _forward = direction == PageTurnDirection.forward;
    return _targetFor(_forward);
  }

  Future<bool> _targetFor(bool forward) {
    if (_targetForward == forward && _targetJob != null) return _targetJob!;
    _clearTarget();
    _targetForward = forward;
    final token = _targetGeneration;
    // 松手和空闲预读要等同一份双页。失败后允许下一次手势重新准备。
    return _targetJob = _loadTarget(forward, token).whenComplete(() {
      if (token == _targetGeneration && _target == null) _targetJob = null;
    });
  }

  Object? _spreadImageKey(
    _SpreadPair pair,
    List<PreparedPage> materials, {
    required bool current,
  }) {
    final right = pair.right;
    if (right == null ||
        (current &&
            ref.read(searchMenuAppearanceProvider(widget.bookId)) != null)) {
      return null;
    }
    final left = _canvas(pair.left, 0, current: current, spread: pair);
    final other = _canvas(right, 1, current: current, spread: pair);
    for (final page in [left, other]) {
      if (page.selectionRects.isNotEmpty ||
          page.selectionHandles.isNotEmpty ||
          page.highlights.isNotEmpty ||
          page.thoughtMarkers.isNotEmpty ||
          page.speechRects.isNotEmpty) {
        return null;
      }
    }
    return (
      materials,
      pair.left.layout.page(pair.left.pageIndex),
      right.layout.page(right.pageIndex),
      left.information?.paintingKey,
      other.information?.paintingKey,
      widget.settings.theme,
      widget.settings.settings.bookEdges,
      _size,
      MediaQuery.devicePixelRatioOf(context),
    );
  }

  Future<void> _rasterSpread(
    _SpreadPair pair,
    List<PreparedPage> materials, {
    required bool current,
    required int token,
  }) async {
    if (materials.any((page) => page.hasFailedImages)) return;
    final key = _spreadImageKey(pair, materials, current: current);
    if (key == null) return;
    // 命中时刷新顺序，新的邻页不能挤掉刚从邻页变为当前页的画面。
    final ready = _spreadImages.remove(key);
    if (ready != null) {
      _spreadImages[key] = ready;
      return;
    }
    final ratio = MediaQuery.devicePixelRatioOf(context);
    final width = (_size.width * ratio).ceil(),
        height = (_size.height * ratio).ceil();
    if (width * height * 4 > PageRasterCache.maxPageBytes) return;
    final picture = _recordPair(pair, materials, current: current);
    try {
      final image = await picture.toImage(width, height);
      if (!mounted || token != _targetGeneration) {
        image.dispose();
        return;
      }
      _spreadImages.remove(key)?.dispose();
      _spreadImages[key] = image;
      while (_spreadImages.length > 2) {
        _spreadImages.remove(_spreadImages.keys.first)!.dispose();
      }
    } finally {
      picture.dispose();
    }
  }

  void _scheduleSpreadPreparation() {
    _idlePreparation?.cancel();
    final pair = _pair;
    if (pair == null ||
        widget.settings.settings.pageTurnEffect != PageTurnEffect.curl) {
      return;
    }
    // 当前双页已交给绘制。下一轮事件就可以开始读邻页，无须再固定等一帧。
    _idlePreparation = Timer(Duration.zero, () async {
      if (!mounted || _pair != pair || _moving || !isReady) return;
      try {
        final job = _targetFor(_forward), token = _targetGeneration;
        final available = await job;
        if (!mounted ||
            token != _targetGeneration ||
            _moving ||
            _pair != pair) {
          return;
        }
        await _rasterSpread(pair, _materials, current: true, token: token);
        if (!mounted ||
            token != _targetGeneration ||
            _moving ||
            !available ||
            _target == null) {
          return;
        }
        await _rasterSpread(
          _target!,
          _targetMaterials,
          current: false,
          token: token,
        );
      } on LayoutCancelled {
        // 目录跳转或新视口已经接管。
      } catch (error, stack) {
        if (mounted && _pair == pair) {
          AppErrors.report(error, stack, operation: '预读相邻双页');
        }
      }
    });
  }
  Future<ScanPreparation> _prepareScan(_SpreadPair pair) async {
    final generation = _generation;
    final origin = _focusOf(pair)!;
    bool current() => mounted && generation == _generation && _pair == pair;
    final next = await _resolve(true);
    List<PreparedPage> materials = [];
    ui.Image? before;
    var adopted = false;
    void release() {
      if (adopted) return;
      for (final page in materials) {
        page.dispose();
      }
      next?.releaseLayouts();
    }

    try {
      if (!current()) throw StateError('双列排版已更新');
      if (next != null) materials = await _load(next);
      if (!current()) throw StateError('双列排版已更新');
      before = _image(pair, _materials, current: true);
      final after = next == null
          ? null
          : _image(next, materials, current: false);
      return ScanPreparation(
        ScanFrames(before, after),
        next == null
            ? null
            : () async {
                if (!current()) return;
                _request = (
                  next.left.layout.page(next.left.pageIndex),
                  next.left.layout.options.layoutSignature,
                  null,
                );
                await _reader.commitSpreadPage(origin, next.left);
                if (!current()) return;
                _presentPair(next, materials);
                adopted = true;
              },
        footerTarget: next?.right ?? next?.left,
        targetPage: next == null
            ? null
            : (next.left.layout.chapterId, next.left.pageIndex),
        onDispose: release,
      );
    } catch (_) {
      before?.dispose();
      release();
      rethrow;
    }
  }

}
