part of '../views/reader_view.dart';

/// 正文区承载盒子：键盘弹出时也保持「没有键盘」时的高度。
///
/// 高度被固定后，页内绘制原点与分页参数都不随键盘变化，
/// 正文和上下信息区不会被顶动；多出来的部分落到键盘/面板后面。
class _ReaderCanvas extends StatelessWidget {
  const _ReaderCanvas({required this.height, required this.child});

  final double height;
  final Widget child;

  @override
  Widget build(BuildContext context) => OverflowBox(
    alignment: Alignment.topCenter,
    minHeight: height,
    maxHeight: height,
    child: child,
  );
}

extension _ReaderPagePreparation on _PageAreaState {
  void _prepareWindow(
    ChapterLayout source,
    int index,
    List<PageCanvas> neighbors, {
    required PageCanvas current,
  }) {
    final configuration = createLocalImageConfiguration(context);
    _pageMaterials.retain([current, ...neighbors], configuration);
    if (_currentMaterial case final prepared?) {
      if (prepared.page.layout.samePageAs(
        source,
        prepared.page.pageIndex,
        index,
      )) {
        _pageMaterials.remember(prepared, configuration);
      }
    }
    // 当前页不变时，增量分页仍可能刚刚提供了邻页，不能漏掉这次准备。
    final key = (
      source.page(index),
      configuration,
      widget.settings.theme,
      widget.settings.settings.pageTurnEffect,
      current.information?.paintingKey,
      neighbors.isEmpty
          ? null
          : neighbors.first.layout.page(neighbors.first.pageIndex),
      neighbors.length < 2
          ? null
          : neighbors.last.layout.page(neighbors.last.pageIndex),
    );
    if (_windowKey == key) return;
    _windowKey = key;
    _textPreparationTimer?.cancel();
    unawaited(() async {
      if (widget.session.book.format == BookFormat.pdf) {
        final ids = {
          source.chapterId,
          for (final page in neighbors) page.layout.chapterId,
        };
        await _materialRepository.retainReadingChapters(
          widget.bookId,
          _materialOwner,
          widget.session.chapters
              .where((chapter) => ids.contains(chapter.id))
              .toList(),
        );
      }
      if (!mounted || _windowKey != key) return;
      await Future.wait([
        for (final page in neighbors)
          _pageMaterials.prepare(page, configuration),
      ]);
      if (!mounted || _windowKey != key) return;
      _preparedLayout = source;
      _preparedPage = index;
      // 首屏当前及邻页材料齐备后才允许无关补排，触摸和动画仍可暂停它。
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted || _windowKey != key) return;
        if (!ReaderDisplayTransition.isCovering(context)) {
          _presenter?.confirmSimplifiedPage(source, index);
        }
        final shown = ReaderPageReady.shownOf(context);
        if (shown != null) await shown;
        _prepareNeighborText(key, neighbors, source, current);
      });
      WidgetsBinding.instance.scheduleFrame();
    }());
  }

  void _prepareNeighborText(
    Object key,
    List<PageCanvas> neighbors,
    ChapterLayout source,
    PageCanvas current, [
    int index = 0,
  ]) {
    if (!mounted || _windowKey != key) return;
    if (index == neighbors.length) {
      _prepareRasterWindow(key, [
        current,
        if (neighbors.isNotEmpty)
          _rasterBackward ? neighbors.last : neighbors.first,
      ], source);
      return;
    }
    final busy =
        LayoutWorkGate.turnPreparationBlocked ||
        WidgetsBinding.instance.transientCallbackCount > 0;
    // 不排入会在动画期间不断重试的空闲任务队列。每页让出一次事件循环，
    // 触摸／动画期间最多每16ms检查一次，切页与退出可以直接取消等待。
    _textPreparationTimer = Timer(Duration(milliseconds: busy ? 16 : 0), () {
      if (!mounted || _windowKey != key) return;
      if (LayoutWorkGate.turnPreparationBlocked ||
          WidgetsBinding.instance.transientCallbackCount > 0) {
        _prepareNeighborText(key, neighbors, source, current, index);
        return;
      }
      neighbors[index].prepareText();
      _prepareNeighborText(key, neighbors, source, current, index + 1);
    });
  }

  void _prepareRasterWindow(
    Object key,
    List<PageCanvas> pages,
    ChapterLayout source, [
    int index = 0,
  ]) {
    if (!mounted || _windowKey != key) return;
    final effect = widget.settings.settings.pageTurnEffect;
    if (index == pages.length ||
        (effect != PageTurnEffect.curl && effect != PageTurnEffect.cover)) {
      source.resumeBackground();
      return;
    }
    bool busy() =>
        LayoutWorkGate.turnPreparationBlocked ||
        WidgetsBinding.instance.transientCallbackCount > 0;
    _textPreparationTimer = Timer(
      Duration(milliseconds: busy() ? 16 : 0),
      () async {
        if (!mounted || _windowKey != key) return;
        if (busy()) {
          _prepareRasterWindow(key, pages, source, index);
          return;
        }
        final configuration = createLocalImageConfiguration(context);
        final prepared =
            _pageMaterials.find(pages[index], configuration) ??
            await PreparedPage.load(pages[index], configuration);
        try {
          if (!mounted || _windowKey != key) return;
          if (busy()) {
            _prepareRasterWindow(key, pages, source, index);
            return;
          }
          await _rasterCache.prepare(
            prepared,
            context.size!,
            MediaQuery.devicePixelRatioOf(context),
          );
        } finally {
          prepared.dispose();
        }
        _prepareRasterWindow(key, pages, source, index + 1);
      },
    );
  }
}
