part of '../views/reader_view.dart';

extension _ReaderPageSelection on _PageAreaState {
  /// 拖动点超出正文盒子上下沿时，算出要往前/往后跳几页（0 表示在盒子内）
  int _pageOffsetFor(Offset point, Size contentSize) {
    if (point.dy < 0) {
      return -(1 + (-point.dy / contentSize.height).ceil());
    }
    if (point.dy > contentSize.height) {
      return 1 + ((point.dy - contentSize.height) / contentSize.height).floor();
    }
    return 0;
  }

  /// 长按/拖动：把页面坐标换算到正文盒子坐标，再问引擎落在哪个字上
  Future<void> _onLongPress(
    Offset localPosition,
    BoxConstraints area,
    Size contentSize, {
    bool extend = false,
  }) async {
    final request = extend ? _selectionRequest : ++_selectionRequest;
    // 手指可能在分词完成前已经开始移动。先从最初按下的字起选，再扩选。
    if (extend) await _startingSelection;
    if (!mounted || request != _selectionRequest) return;
    await ref.read(automaticReadingProvider(widget.bookId).notifier).discard();
    if (!mounted || request != _selectionRequest) return;
    final session = widget.session;
    final layout = session.layout;
    if (layout == null) return;
    final info = readerInformation(
      context,
      ref,
      session,
      widget.settings.settings,
      widget.settings.theme,
      session.chapterIndex,
      session.chapterProgress,
    );
    // 起选位置与整页画布中的正文原点一致。
    final origin = Offset(
      (area.maxWidth - contentSize.width) / 2,
      (area.maxHeight - contentSize.height + info.top - info.bottom) / 2,
    );
    final engine = ref.read(readerEngineProvider);
    final point = localPosition - origin;
    final vm = ref.read(readerProvider.notifier);
    final state = ref.read(readerProvider);
    // 还没起选，或现在这段选区是「点已有高亮」选出来的：都按新选文开始，
    // 不在旧高亮的范围上接着延伸（用户口径：改范围要重新选文字）
    if (state.selection == null || state.selectionFromMark) {
      if (extend) return;
      final range = await engine.initialSelectionAtPoint(
        layout,
        session.pageIndex,
        point,
      );
      if (!mounted ||
          range == null ||
          request != _selectionRequest ||
          _pageTurning ||
          widget.session.layout != layout ||
          widget.session.pageIndex != session.pageIndex ||
          ref.read(readerProvider).controlsVisible ||
          ref.read(readerProvider).selection != state.selection) {
        return;
      }
      vm.startSelection(range.start, range.end);
      return;
    }
    // 拖出页面下沿/上沿：按拖出的距离整页整页地往后/往前选（原型口径）
    final beyond = _pageOffsetFor(point, contentSize);
    if (beyond != 0) {
      final target = (session.pageIndex + beyond)
          .clamp(0, math.max(0, layout.pageCount - 1))
          .toInt();
      final edge = pageEdgeLocator(
        layout: layout,
        pageIndex: target,
        atEnd: beyond > 0,
      );
      if (edge != null) vm.extendSelection(edge);
      return;
    }
    final locator = engine.locatorAtPoint(layout, session.pageIndex, point);
    if (locator == null) return;
    vm.extendSelection(locator);
  }

  void _showNotice(String message) =>
      ref.read(readerProvider.notifier).showNotice(message);
}
