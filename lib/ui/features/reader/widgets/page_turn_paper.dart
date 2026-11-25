part of 'page_turn_area.dart';

extension _PageTurnPaper on _PageTurnAreaState {
  Widget _paperStack(BuildContext context, Size size) {
    final footer = BookPagePaperScope.of(context);
    final width = size.width;
    final frames = _fold;
    final target = frames?.numberedTarget;
    final backward = _direction == PageTurnDirection.backward;
    Widget sheet(Widget body, {bool next = false}) =>
        footer == null || (next && target == null)
        ? body
        : footer.onPaper(body, size, page: next ? target : footer.current);
    if (_offset.abs() > 0.1 &&
        (_fold != null || (widget.prepareFold == null && _neighbour != null))) {
      _responseTrace.changedFrame(widget.traceLabel);
    }
    if (widget.effect == PageTurnEffect.none) return sheet(widget.currentPage);
    // 三种动画统一交接完整正文：动画中复用当前图，落页时接收目标图。
    // 各分支只负责几何画法，不能各自决定是否重新加载正文图片。
    final current = RepaintBoundary(
      child: PreparedPageTransfer(
        page: _landing ?? _fold?.preparedCurrent,
        child: widget.currentPage,
      ),
    );
    // 原书平移复用已经确认的原尺寸截图。两页一起移动，不能套用底页不动的覆盖画法。
    // 没准备好时仍显示旧页；拖动期间不再逐次等待 WebView 执行位移。
    if (widget.slideImages &&
        widget.effect == PageTurnEffect.slide &&
        _fold?.hasPageImages == true) {
      if (footer != null && target != null) {
        return Stack(
          fit: StackFit.expand,
          children: _flatFrameSheets(frames!, size, backward, sheet).toList(),
        );
      }
      return CustomPaint(
        willChange: true,
        painter: SlideFramesPainter(
          _fold!,
          _offset,
          _direction == PageTurnDirection.backward,
        ),
      );
    }
    if ((widget.effect == PageTurnEffect.curl ||
            widget.effect == PageTurnEffect.cover) &&
        widget.prepareFold != null) {
      final curl = frames == null || widget.effect != PageTurnEffect.curl
          ? null
          : FoldFramesPainter(
              frames,
              _foldProgress,
              backward,
              _fromTop,
              touchPosition: _touchPosition,
              edgeCurl: _edgeCurl,
              edgeOriginY: _edgeOriginY,
              settledTouch: _settledTouch,
            );
      return Stack(
        fit: StackFit.expand,
        children: [
          // 简化排版的动画就绪后会画满整张纸。保留正文及其布局，省去下面那张不可见的整页绘制。
          Opacity(
            opacity:
                frames != null &&
                    frames.preparedCurrent != null &&
                    frames.paper.a == 1
                ? 0
                : 1,
            alwaysIncludeSemantics: true,
            child: current,
          ),
          if (frames == null && footer != null)
            footer.footerFor(footer.current!, width),
          // 连续变化的卷页无需让引擎尝试缓存每一帧不同的绘制结果。
          if (curl != null)
            if (footer != null && target != null)
              footer.curl(curl, size, target)
            else
              CustomPaint(willChange: true, painter: curl)
          else if (frames != null)
            if (footer != null && target != null)
              ..._flatFrameSheets(frames, size, backward, sheet)
            else
              CustomPaint(
                willChange: true,
                painter: CoverFramesPainter(frames, _offset, backward),
              ),
        ],
      );
    }
    final neighbour = _neighbour;
    if (neighbour == null && widget.effect != PageTurnEffect.slide) {
      return sheet(current);
    }

    final forward = _direction == PageTurnDirection.forward;
    if (widget.effect == PageTurnEffect.cover) {
      // 未使用图片缓存的调用方也遵循同一覆盖顺序，底页始终不动。
      return Stack(
        fit: StackFit.expand,
        children: [
          forward ? sheet(neighbour!, next: true) : sheet(current),
          Positioned(
            left: forward ? _offset : _offset - width,
            top: 0,
            bottom: 0,
            width: width,
            child: forward ? sheet(current) : sheet(neighbour!, next: true),
          ),
        ],
      );
    }
    // 和卷页一样，图片未准备好时保留整张旧页，不能先推开正文露出空白。
    final showNeighbour =
        neighbour != null && (widget.prepareFold == null || _fold != null);
    final slide = showNeighbour && _fold?.hasPreparedSlide == true;
    return Stack(
      children: [
        if (showNeighbour && !slide)
          Positioned(
            key: const ValueKey('neighbour-page'),
            left: 0,
            top: 0,
            width: width,
            bottom: 0,
            child: Transform.translate(
              offset: Offset(forward ? width + _offset : _offset - width, 0),
              child: RepaintBoundary(
                child: PreparedPageTransfer(
                  page: _fold?.preparedTarget,
                  child: sheet(neighbour, next: true),
                ),
              ),
            ),
          ),
        Positioned(
          // 平移前后保留同一正文实例，并接收动画已解码的图片，避免重新加载闪页。
          key: const ValueKey('current-page'),
          left: 0,
          top: 0,
          width: width,
          bottom: 0,
          // 只改绘制位置，不逐帧重新布局整页。正文实例和图片交接保持不变。
          child: Transform.translate(
            offset: Offset(showNeighbour ? _offset : 0, 0),
            child: Opacity(
              opacity: slide ? 0 : 1,
              alwaysIncludeSemantics: true,
              child: sheet(current),
            ),
          ),
        ),
        if (slide)
          Positioned.fill(
            child: footer != null && target != null
                ? Stack(
                    fit: StackFit.expand,
                    children: _flatFrameSheets(
                      frames!,
                      size,
                      backward,
                      sheet,
                    ).toList(),
                  )
                : PreparedSlide(_fold!, _offset, !forward, width),
          ),
      ],
    );
  }

  Iterable<Widget> _flatFrameSheets(
    FoldFrames frames,
    Size size,
    bool backward,
    Widget Function(Widget, {bool next}) sheet,
  ) sync* {
    final cover = widget.effect == PageTurnEffect.cover;
    final leafWidth = frames.leafSize(size).width;
    final left = frames.coverLeft(size, _offset, backward);
    for (final next in cover ? [!backward, backward] : [true, false]) {
      final top = next == backward;
      final x = cover
          ? (top ? left : 0.0)
          : _offset + (next ? (backward ? -size.width : size.width) : 0);
      final body = sheet(
        RepaintBoundary(
          child: CustomPaint(
            painter: FlatFramePage(
              frames,
              next: next,
              backward: backward,
              cover: cover,
            ),
          ),
        ),
        next: next,
      );
      yield Transform.translate(
        offset: Offset(x, 0),
        child: cover && top
            ? ClipRect(
                clipper: _SheetClip(
                  Rect.fromLTWH(0, 0, leafWidth, size.height),
                ),
                child: body,
              )
            : body,
      );
      if (cover &&
          !top &&
          left + leafWidth > 0 &&
          left + leafWidth < leafWidth) {
        yield Positioned(
          left: left + leafWidth,
          top: 0,
          bottom: 0,
          width: 10,
          child: const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [Color(0x33000000), Colors.transparent],
              ),
            ),
          ),
        );
      }
    }
  }
}

class _SheetClip extends CustomClipper<Rect> {
  const _SheetClip(this.bounds);
  final Rect bounds;
  @override
  Rect getClip(Size size) => bounds;
  @override
  bool shouldReclip(_SheetClip old) => bounds != old.bounds;
}
