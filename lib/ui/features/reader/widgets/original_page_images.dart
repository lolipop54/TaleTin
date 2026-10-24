part of 'original_curl_area.dart';

/// 正文原图与带信息的整页图分开保留，分钟／书签变化只重画信息。
/// 最多各三张；起手命中时直接克隆已准备的GPU图像，避免再次整页栅格化。
extension _OriginalPageImages on OriginalCurlAreaState {
  bool _hasTurnImages(bool backward) {
    final host = widget.host, known = _knownPage;
    if (host == null || known == null || known.$1 != host) return false;
    final target = _directions[(_pageKey(host, known.$2), backward)];
    if (target == null) return false;
    return _hasPage(host, known.$2, widget.information) &&
        _hasPage(
          target.host,
          target.page,
          _freshInformation(target).information,
        );
  }

  // 平移保留网页自身的信息字体和书边SVG，不用Flutter重画来替换原来的外观。
  // 页内进度固定于页序；时钟、电量、书签索引等变化才需要刷新原生整页图。
  Object _nativeInformationKey(
    OriginalHostController host,
    PageInformation? info,
  ) => (
    info?.clock,
    info?.battery,
    info?.fontFamily,
    info?.color,
    info?.visible,
    info?.inset,
    info?.bottomInset,
    info?.scaler.scale(11),
    info?.scaler.scale(12),
    info?.searchMenu?.svg,
    host.pageCount,
    Object.hashAll(
      host.bookmarkPages.entries.map((e) => Object.hash(e.key, e.value)),
    ),
  );

  bool _hasPage(OriginalHostController host, int page, PageInformation? info) {
    final key = _pageKey(host, page);
    return _pages.containsKey(key) &&
        (widget.effect != PageTurnEffect.slide ||
            _nativeInformationVersions[key] ==
                _nativeInformationKey(host, info));
  }

  Future<ui.Image> _pageImage(
    OriginalHostController host,
    int page,
    PageInformation? information,
    Size size,
  ) async {
    final key = (
      _pageKey(host, page),
      information?.paintingKey,
      widget.paper,
      widget.bookEdges,
      widget.spread,
      size,
    );
    if (widget.effect == PageTurnEffect.slide &&
        !_hasPage(host, page, information)) {
      _pages.remove(key.$1)?.dispose();
      _paintedPages.removeWhere((old, value) {
        if (old.$1 != key.$1) return false;
        value.dispose();
        return true;
      });
    }
    final cached = _paintedPages.remove(key);
    ReaderRecoveryDiagnostics.record('paintedPage', {
      'page': page,
      'host': identityHashCode(host),
      'hit': cached != null,
      'targetWidth': size.width,
      'targetHeight': size.height,
      'imageWidth': cached?.width,
      'imageHeight': cached?.height,
    });
    if (cached != null) {
      _paintedPages[key] = cached;
      final body = _pages.remove(key.$1);
      if (body != null) _pages[key.$1] = body;
      return cached.clone();
    }
    final generation = _generation;
    final image = _withInformation(
      await _capture(host, page),
      information,
      size,
    );
    if (mounted && generation == _generation) {
      if (widget.effect == PageTurnEffect.slide) {
        _nativeInformationVersions[key.$1] = _nativeInformationKey(
          host,
          information,
        );
      }
      // 同一正文页只留当前信息版本，分钟变化不挤掉另外两页。
      _paintedPages.removeWhere((old, value) {
        if (old.$1 != key.$1) return false;
        value.dispose();
        return true;
      });
      _paintedPages[key] = image.clone();
      while (_paintedPages.length > 3) {
        _paintedPages.remove(_paintedPages.keys.first)!.dispose();
      }
    }
    return image;
  }

  Future<ui.Image> _capture(
    OriginalHostController host,
    int page, {
    bool preview = false,
  }) async {
    final key = _pageKey(host, page);
    final cached = _pages.remove(key);
    ReaderRecoveryDiagnostics.record('bodyPageImage', {
      'page': page,
      'host': identityHashCode(host),
      'hit': cached != null,
      'captureVersion': key.$3,
      'generation': _generation,
      'imageWidth': cached?.width,
      'imageHeight': cached?.height,
    });
    if (cached != null) {
      traceTurn(
        'cache hit host=${identityHashCode(host)} page=$page version=${key.$3}',
      );
      _pages[key] = cached;
      return cached.clone();
    }
    final generation = _generation;
    traceTurn(
      'cache miss host=${identityHashCode(host)} page=$page version=${key.$3} preview=$preview',
    );
    final image = await (preview ? host.capturePage(page) : host.capture());
    ReaderRecoveryDiagnostics.record('bodyPageCaptured', {
      'page': page,
      'host': identityHashCode(host),
      'imageWidth': image.width,
      'imageHeight': image.height,
      'generation': generation,
      'currentGeneration': _generation,
    });
    if (mounted && generation == _generation) {
      _pages[key] = image.clone();
      // 当前页及前后页就绪后，起手直接使用图像与页序，不调用 WebView。
      while (_pages.length > 3) {
        final oldest = _pages.keys.first;
        _pages.remove(oldest)!.dispose();
        _nativeInformationVersions.remove(oldest);
      }
      _directions.removeWhere((key, _) => !_pages.containsKey(key.$1));
    }
    return image;
  }

  // 静止页与截图使用同一套信息区画法，避开 WebView 软件截图的文字偏移。
  ui.Image _withInformation(ui.Image source, PageInformation? info, Size size) {
    if (info == null || widget.effect == PageTurnEffect.slide) return source;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder)
      ..scale(source.width / size.width, source.height / size.height);
    canvas.drawColor(widget.paper, BlendMode.src);
    canvas.drawImageRect(
      source,
      Rect.fromLTWH(0, 0, source.width.toDouble(), source.height.toDouble()),
      Offset.zero & size,
      Paint(),
    );
    if (widget.bookEdges || widget.spread) {
      BookPaperPainter(
        widget.paper,
        edges: widget.bookEdges,
        spread: widget.spread,
        decorationOnly: true,
      ).paint(canvas, size);
    }
    // 返回进度／搜索面板必须在书脊装饰上面，截图和静止页使用同一顺序。
    info.paint(canvas, size);
    final picture = recorder.endRecording();
    final image = picture.toImageSync(source.width, source.height);
    picture.dispose();
    source.dispose();
    return image;
  }
}
