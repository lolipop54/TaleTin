part of 'scroll_selection_layer.dart';

/// 端点身份固定。贴着上/下边缘时缓慢滚动，随后按新正文更新同一端。
mixin _ScrollSelectionDrag on ConsumerState<ScrollSelectionLayer> {
  Offset? _dragPoint;
  bool _dragAtEnd = true, _moving = false, _edgeMoving = false;
  Timer? _edgeTimer;
  Future<void>? _pendingMove;
  Future<void>? _pendingEdge;
  int _dragVersion = 0;

  Widget _handle(Offset anchor, bool end, Size viewport) => Positioned(
    // 跨屏后另一端可能消失，用固定 key 保留正在拖动的手势对象。
    key: ValueKey(('scroll-handle', end)),
    left: (anchor.dx - 22).clamp(0, viewport.width - 44),
    top: anchor.dy.clamp(0, viewport.height - 44), width: 44, height: 44,
    child: GestureDetector(key: ValueKey(end ? kHandleEndKey : kHandleStartKey),
      behavior: HitTestBehavior.opaque,
      onPanStart: (_) {
        ++_dragVersion;
        _dragAtEnd = end; _dragPoint = anchor;
        setState(() {});
      },
      onPanUpdate: (event) {
        _dragPoint = _dragPoint! + event.delta;
        unawaited(_moveEndpoint());
        _edgeTimer ??= Timer.periodic(const Duration(milliseconds: 80), (_) => unawaited(_edgeStep()));
      },
      onPanEnd: (_) => unawaited(_commitDrag()), onPanCancel: _finishDrag,
      child: CustomPaint(painter: SelectionHandlePainter(
        color: readingLinkColor(widget.theme), atEnd: end))));

  Future<void> _moveEndpoint() {
    if (_moving) return _pendingMove ?? Future.value();
    return _pendingMove = _queryEndpoint(_dragVersion);
  }
  Future<void> _queryEndpoint(int version) async {
    final point = _dragPoint;
    if (point == null || !mounted || _moving) return;
    _moving = true;
    try {
      final size = context.size!;
      final locator = await widget.backend.hit(Offset(point.dx.clamp(0, size.width),
        point.dy.clamp(1, size.height - 1)));
      if (!mounted || version != _dragVersion || _dragPoint == null || locator == null) return;
      final vm = ref.read(readerProvider.notifier);
      if (_dragAtEnd) { vm.setSelectionEnd(locator); } else { vm.setSelectionStart(locator); }
    } finally {
      _moving = false;
      if (mounted && _dragPoint != null && (version != _dragVersion || _dragPoint != point)) {
        await _moveEndpoint();
      }
    }
  }
  Future<void> _edgeStep() {
    if (_edgeMoving) return _pendingEdge ?? Future.value();
    return _pendingEdge = _moveAtEdge();
  }
  Future<void> _moveAtEdge() async {
    final point = _dragPoint;
    if (point == null || !mounted || _moving || _edgeMoving) return;
    final height = context.size!.height;
    final direction = point.dy < 36 ? -1 : point.dy > height - 44 ? 1 : 0;
    if (direction == 0) return;
    _edgeMoving = true;
    try {
      await widget.backend.move(direction * 12);
      if (mounted && _dragPoint != null) await _moveEndpoint();
    } finally { _edgeMoving = false; }
  }
  Future<void> _commitDrag() async {
    _edgeTimer?.cancel(); _edgeTimer = null;
    final version = _dragVersion;
    // 网页命中查询会晚于松手返回，等最后落点写入后再收起手柄。
    await _pendingEdge;
    await _moveEndpoint();
    if (mounted && version == _dragVersion) _finishDrag();
  }
  void _finishDrag({bool rebuild = true}) {
    ++_dragVersion;
    _edgeTimer?.cancel(); _edgeTimer = null; _dragPoint = null;
    if (rebuild && mounted) setState(() {});
  }
}

class _ScrollMarkPainter extends CustomPainter {
  _ScrollMarkPainter(this.geometry, this.marks, this.hasRange, this.paintRange,
    this.theme, this.hasSpeech);
  final List<ScrollRangeGeometry> geometry;
  final List<Annotation> marks;
  final bool hasRange, paintRange, hasSpeech;
  final ReadingTheme theme;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.save(); canvas.clipRect(Offset.zero & size);
    var index = 0;
    void paintRects(ScrollRangeGeometry value, Color color) {
      for (final rect in value.rects) { canvas.drawRect(rect, Paint()..color = color); }
    }
    if (hasRange && geometry.isNotEmpty) {
      if (paintRange) paintRects(geometry.first, const Color(0x66B7D3F6));
      index++;
    }
    for (final mark in marks) {
      if (index >= geometry.length) break;
      final value = geometry[index++];
      paintRects(value, pageHighlightColorOf(mark.color));
      if (mark.hasBody && value.end != null && value.rects.isNotEmpty) {
        paintThoughtMarker(canvas, thoughtMarkerRect(value.rects.last, size.width), readingLinkColor(theme));
      }
    }
    if (hasSpeech && index < geometry.length) paintRects(geometry[index], theme.speechHighlight);
    canvas.restore();
  }
  @override
  bool shouldRepaint(_ScrollMarkPainter old) => true;
}
