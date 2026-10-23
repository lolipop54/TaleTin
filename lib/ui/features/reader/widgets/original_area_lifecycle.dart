part of 'original_reader_area.dart';

/// 统一登记和释放阅读区的前台工作、导航与平台回调。
extension _OriginalAreaLifecycle on _OriginalReaderAreaState {
  void _initReadingArea() {
    widget.foregroundWork?.addListener(_displayWorkChanged);
    _displayWorkChanged();
    _progressNotifier.cancelOriginalProgressPreparation =
        _cancelProgressPreparation;
    _initSpeech();
    _preload.addListener(_resumeBackground);
    // 兜底：手指抬起的事件可能被平台视图（WebView）拿走，手柄的 onPanEnd/
    // onPanCancel 收不到，拖动态一直挂着——页沿计时一页页续下去，页面翻个不停、
    // 手柄却落在别的页（真机反馈的「翻页后看不到也拖不动手柄」）
    GestureBinding.instance.pointerRouter.addGlobalRoute(_onGlobalPointer);
    widget.controller.holdPageDuringJump = _holdPageDuringJump;
    widget.controller.prepareProgressChapter = _prepareProgressChapter;
    widget.controller.visiblePageAnchor = _visiblePageAnchor;
    _slideAnim.addListener(() {
      final tween = _slideTween;
      if (tween == null) return;
      _slide = tween.value;
    });
    _slideAnim.addStatusListener((status) {
      if (status != AnimationStatus.completed) return;
      final done = _slideDone;
      _slideDone = null;
      done?.call();
      _preload.release('slide');
    });
  }

  void _disposeReadingArea() {
    widget.foregroundWork?.removeListener(_displayWorkChanged);
    final notifier = _progressNotifier;
    if (notifier.cancelOriginalProgressPreparation ==
        _cancelProgressPreparation) {
      notifier.cancelOriginalProgressPreparation = null;
    }
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_onGlobalPointer);
    _speechLog('disposed');
    _speech.diagnostics.dispose();
    _speech.lifecycle.dispose();
    _speech.service.setPageBoundaries(this, const []);
    widget.controller.holdPageDuringJump = null;
    widget.controller.prepareProgressChapter = null;
    widget.controller.visiblePageAnchor = null;
    _jumpCover?.dispose();
    _finishCurlHandover(false);
    for (final ready in _pageReady.values) {
      if (!ready.isCompleted) ready.complete(false);
    }
    _slideAnim.dispose();
    _slidePosition.dispose();
    _switchGuard?.cancel();
    _preload.dispose();
    _entrySlideGuard?.cancel();
    _waitingNeighborGuard?.cancel();
  }
}
