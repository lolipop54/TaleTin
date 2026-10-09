part of 'original_reader_area.dart';

/// 原书选区手柄在测试与调试里的定位键（与简化模式的手柄分开）
const String kOriginalHandleStartKey = 'original-selection-handle-start';
const String kOriginalHandleEndKey = 'original-selection-handle-end';

/// 拖动扩选翻页后，等滑动动画走完再问页边位置的时长。
///
/// 比宿主页的 transform 过渡（220ms）多留一点余量；不等就会量到正在滑走的旧页。
/// 仿真/覆盖翻页下宿主页不播 transform，这个等待只是让扩选慢一点起步。
const Duration kSelectionTurnSettle = Duration(milliseconds: 260);

/// 原书选区的手柄拖动与页沿翻页（实现计划 S5）。
///
/// 与简化模式同一套手感：手柄画在高亮下方一小段距离，拖的时候手指不挡字；
/// **拖到正文左上角停够 0.8 秒翻上一页；右下角停够 0.8 秒翻下一页**。
/// 翻完页后拖动的那一端按手柄最新位置定位；落点在正文外时才取新页的
/// 页首/页末，接着拖就能继续跨页高亮；整段选区只有一对手柄。
///
/// 位置换算：手柄落点是阅读页坐标，先减掉 WebView 原点再换算成宿主页的
/// CSS 像素，交给宿主页问「这一点在哪一段文字上」，回来仍是标准正文 Locator。
/// 每一次落点都要跨语言往返，所以拖动只在**上一次算完**之后取最新位置，
/// 中间的位置丢掉（与宿主页拖动同一口径），不让旧结果盖住新结果。
extension _OriginalSelectionDrag on _OriginalReaderAreaState {
  /// 手柄拖动开始：标记正在拖（翻页扩选期间选区要留着）
  void _beginSelectionDrag(bool atEnd) {
    _selection.dragging = true;
    unawaited(_host?.selectionHandleDrag(atEnd));
  }

  /// 拖动中的最新落点（手柄位置与手指位置都在阅读页坐标里）
  Future<void> _dragSelection(bool atEnd, Offset handle, Offset finger) {
    _pendingDragHandle = handle;
    _pendingDragFinger = finger;
    _pendingDragEnd = atEnd;
    _selection.dragHandle = handle;
    _selection.dragging = true;
    // 落页期间只记最新手指位置，不能在正在平移的正文上计算选区。
    if (_selection.turning) return Future<void>.value();
    return _selectionDragFlight ??= _drainSelectionDrag();
  }

  Future<void> _drainSelectionDrag() async {
    try {
      while (_pendingDragHandle != null && !_selection.turning) {
        final handle = _pendingDragHandle!;
        final finger = _pendingDragFinger!;
        final atEnd = _pendingDragEnd;
        _pendingDragHandle = null;
        await _applySelectionPoint(atEnd, handle);
        if (!mounted) return;
        if (_selection.turning) return;
        // 手指已经松开：这一次落点只是补算位置，不再判页沿、不翻页
        // （否则松手之后还会因为一个迟到的落点把页翻过去）
        if (!_selection.dragging) return;
        _updateSelectionEdge(handle, finger);
      }
    } finally {
      _selectionDragFlight = null;
    }
  }

  /// 拖动结束：撤销页沿计时与提示，落下拖动状态。
  ///
  /// 正在翻页交接时选区要留着（[turning] 决定），但拖动本身已经结束：
  /// 迟到的落点不能再触发翻页。
  void _finishSelectionDrag() {
    unawaited(_host?.selectionHandleDrag(null));
    _cancelSelectionEdge();
    _pendingDragHandle = null;
    _pendingDragFinger = null;
    _selection.dragging = false;
    // 松手可能早于落页完成，最后的落点仍用于本次落页，但不再续翻。
    _showSelectionEdgeHint(null);
  }

  /// 一次落点：改选区当前在拖的那一端，再按新范围重取矩形
  Future<void> _applySelectionPoint(bool atEnd, Offset handle) async {
    final host = _host;
    final session = widget.session;
    final content = session.content;
    final href = session.chapter.href;
    if (host == null || content == null || href == null) return;
    final version = _selection.version;
    final point = await host.selectionPointAt(_toViewport(handle));
    if (point == null || !_selectionCurrent(version, host)) return;
    final map = await _selectionMapFor(session.chapterIndex, href, content);
    if (map == null || !_selectionCurrent(version, host)) return;
    final target = map.pointLocatorAt(point);
    if (target == null) return;
    final vm = ref.read(readerProvider.notifier);
    if (atEnd) {
      vm.setSelectionEnd(target);
    } else {
      vm.setSelectionStart(target);
    }
    final range = ref.read(readerProvider).selection;
    if (range == null) return;
    final geometry = await _selectionGeometry(map, range.start, range.end);
    if (geometry == null || !_selectionCurrent(version, host)) return;
    _updateState(() => _applyGeometry(geometry));
  }

  /// 页角判定：手指停在左上角/右下角才翻页，离开角落就撤销。
  void _updateSelectionEdge(Offset handle, Offset finger) {
    if (_selection.turning) return;
    final box = _selection.edgeBox;
    final direction = pageTurnDirectionFor(
      handle: handle - box.topLeft,
      finger: finger - box.topLeft,
      contentSize: box.size,
    );
    if (direction != 0) {
      _startSelectionEdge(direction);
    } else if (!fingerPushedOut(
      finger - box.topLeft,
      box.size,
      _selection.edgeDirection,
    )) {
      _cancelSelectionEdge();
    }
    _showSelectionEdgeHint(handle);
  }

  /// 开始翻页倒计时（已经在计时就不重开）：停在页沿够 0.8 秒翻一页
  void _startSelectionEdge(int direction) {
    if (_selection.edgeDirection != direction) _cancelSelectionEdge();
    _selection.edgeDirection = direction;
    if (_selection.edgeTimer != null) return;
    _selection.edgeTimer = Timer(kEdgeTurnDelay, () {
      _selection.edgeTimer = null;
      unawaited(_turnSelectionPage(direction));
    });
  }

  /// 手指回到正文里或松手：撤销翻页倒计时
  void _cancelSelectionEdge() {
    _selection.edgeDirection = 0;
    _selection.edgeTimer?.cancel();
    _selection.edgeTimer = null;
  }

  /// 停在页沿够时长：翻相邻页，并把拖动的那一端带到新页靠近手指的那一侧。
  ///
  /// 换页期间忽略后续移动（一次只处理一个目标页）；换页完成后若手指仍停在
  /// 页沿就重新计时，一页页往外扩。到书首/书尾宿主页不报新页序，就停住不空翻。
  Future<void> _turnSelectionPage(int direction) async {
    if (_selection.turning || !_selection.dragging) return;
    final host = _host;
    final session = widget.session;
    final content = session.content;
    final href = session.chapter.href;
    if (host == null || content == null || href == null) return;
    if (ref.read(readerProvider).selection == null) return;
    final atEnd = _pendingDragEnd;
    final version = _selection.version;
    // 外部扩选也要先等待截图预取还原，不能和临时切页并行修改宿主页页号。
    await _curlKey.currentState?.settleForSpeech();
    if (!_selectionCurrent(version, host) || !_selection.dragging) return;
    _selection.turning = true;
    // 旧页仍在飞的落点不能覆盖新页；下面的落页流程重新取有效位置。
    _selection.version++;
    final turnVersion = _selection.version;
    try {
      final wait = Completer<int>();
      _selection.pageTurn = wait;
      if (direction > 0) {
        await host.next();
      } else {
        await host.prev();
      }
      final page = await wait.future.timeout(
        const Duration(milliseconds: 1200),
        onTimeout: () => -1,
      );
      if (!mounted || page < 0 || host != _host) {
        gtDebugLog('[gt] 翻页扩选没等到新页：page=$page mounted=$mounted');
        return;
      }
      // 等滑动动画走完再问页边：动画期间 `getClientRects` 给的是**正在滑走的
      // 旧页**的位置，量到的「本页第一个字」其实是上一页的字，拖动的那一端
      // 于是落在上一页、手柄全不在本页（真机反馈的「翻页后手柄不见、也拖不动」）。
      // 动画时长与宿主页的 transform 过渡一致（220ms，见 host_layout 的 applyTransform）
      await Future<void>.delayed(kSelectionTurnSettle);
      if (!_selectionCurrent(turnVersion, host)) return;
      // 手柄命不中正文时的备用落点：往后翻取新页页首，往回翻取页末。
      final edge = await host.selectionPageEdge(atEnd: direction < 0);
      final map = await _selectionMapFor(
        widget.session.chapterIndex,
        href,
        content,
      );
      if (map == null || !mounted || host != _host) {
        gtDebugLog('[gt] 翻页扩选建不出对照表');
        return;
      }
      final handle = _selection.dragHandle;
      final hit = handle == null
          ? null
          : await host.selectionPointAt(_toViewport(handle));
      final point = hit ?? edge;
      final target = point == null ? null : map.pointLocatorAt(point);
      gtDebugLog(
        '[gt] 扩选翻页 dir=$direction 页=$page '
        '页边=${edge == null ? 'null' : '${edge['path']}@${edge['offset']}'} '
        '目标=${target == null ? 'null' : '${target.blockId}#${target.utf16Offset}'}',
      );
      // 拿不到新页首尾文字时**也要**按新页重量一次矩形：页变了以后旧矩形已经
      // 作废（[ _dropSelectionOnPageChange ] 会先清空），不重量手柄就一直是空的，
      // 用户既看不到也抓不到（真机反馈）。
      if (target == null) {
        gtDebugLog('[gt] 翻页扩选拿不到新页首尾文字，只重量矩形');
      } else {
        final vm = ref.read(readerProvider.notifier);
        // 翻页方向和正在拖的端点是两件事：终点往回拖仍然只改终点。
        final landing = atEnd && hit == null
            ? map.nextChar(target) ?? target
            : target;
        if (atEnd) {
          vm.setSelectionEnd(landing);
        } else {
          vm.setSelectionStart(landing);
        }
      }
      final range = ref.read(readerProvider).selection;
      if (range == null) {
        gtDebugLog('[gt] 翻页扩选时选区已经收起');
        return;
      }
      final geometry = await _selectionGeometry(map, range.start, range.end);
      if (geometry == null || !mounted || host != _host) {
        gtDebugLog('[gt] 翻页扩选取不到矩形');
        return;
      }
      _updateState(() => _applyGeometry(geometry));
      _pendingDragHandle = null;
      // 手指还停在页沿：接着计时，再停够一次就再翻一页
      final finger = _pendingDragFinger;
      if (_selection.dragging &&
          finger != null &&
          fingerPushedOut(
            finger - _selection.edgeBox.topLeft,
            _selection.edgeBox.size,
            direction,
          )) {
        _startSelectionEdge(direction);
      }
    } finally {
      _selection.pageTurn = null;
      _selection.turning = false;
    }
  }

  /// 手柄落到页首/页末那一带时说一句「长按这里能翻页」；同一条高亮只说一次
  void _showSelectionEdgeHint(Offset? handle) {
    if (_selection.edgeHintShown || handle == null) return;
    final hint = pageEdgeHintFor(
      handle - _selection.edgeBox.topLeft,
      _selection.edgeBox.size,
    );
    if (hint == null) return;
    _selection.edgeHintShown = true;
    ref.read(readerProvider.notifier).showNotice(hint);
  }
}

/// 原书选区的起止手柄：拖着改选区两端（整段选区只有一对手柄）。
///
/// 手柄位置按选区矩形算：起点贴第一行左下、终点贴最后一行右下，画在行下方
/// 一小段距离处。拖动时手柄改画在手指位置，不再按矩形算——换页那一瞬间
/// 端点可能已经不在新页上，按矩形算会让手柄消失，手势被判取消。
class _OriginalSelectionHandles extends StatefulWidget {
  const _OriginalSelectionHandles({
    required this.startAnchor,
    required this.endAnchor,
    required this.onDragStart,
    required this.onDrag,
    required this.onDragEnd,
    required this.color,
  });

  /// 起点/终点手柄的落点（阅读页坐标）；不在本页的那一端为 null，就不画
  final Offset? startAnchor;
  final Offset? endAnchor;

  final ValueChanged<bool> onDragStart;

  /// (拖的是终点吗, 手柄落点, 手指位置) —— 都在阅读页坐标里
  final void Function(bool atEnd, Offset handle, Offset finger) onDrag;

  final VoidCallback onDragEnd;
  final Color color;

  @override
  State<_OriginalSelectionHandles> createState() =>
      _OriginalSelectionHandlesState();
}

class _OriginalSelectionHandlesState extends State<_OriginalSelectionHandles> {
  /// 正在拖哪一端，以及手柄当前落点
  bool _atEnd = true;
  Offset? _handle;
  Offset _grabOffset = Offset.zero;

  @override
  Widget build(BuildContext context) =>
      Stack(children: [?_handleFor(false), ?_handleFor(true)]);

  /// 一端的手柄；这一端不在本页（矩形里没有它）时返回 null
  Widget? _handleFor(bool atEnd) {
    final dragging = _handle != null && _atEnd == atEnd;
    final anchor = dragging ? _handle : _anchorOf(atEnd);
    if (anchor == null) return null;
    return Positioned(
      key: ValueKey(atEnd ? kOriginalHandleEndKey : kOriginalHandleStartKey),
      left: anchor.dx - kHandleTouchSize / 2,
      top: anchor.dy,
      width: kHandleTouchSize,
      height: kHandleTouchSize,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        // 手柄上按住不放不再起一次选句
        onLongPress: () {},
        onPanDown: (details) =>
            _grabOffset = _localOf(details.globalPosition) - anchor,
        onPanStart: (details) {
          setState(() {
            _atEnd = atEnd;
            // 识别拖动前的位移也要算进去；只累计 delta 会永远落后手指一段。
            _handle = _localOf(details.globalPosition) - _grabOffset;
          });
          widget.onDragStart(atEnd);
          widget.onDrag(atEnd, _handle!, _localOf(details.globalPosition));
        },
        onPanUpdate: (details) {
          final from = _handle;
          if (from == null) return;
          final point = _localOf(details.globalPosition) - _grabOffset;
          setState(() => _handle = point);
          widget.onDrag(atEnd, point, _localOf(details.globalPosition));
        },
        onPanEnd: (_) => _finish(),
        onPanCancel: _finish,
        child: CustomPaint(
          painter: dragging
              ? _HandlePainter(color: widget.color, atEnd: atEnd)
              : null,
        ),
      ),
    );
  }

  /// 手指在阅读页里的位置。
  ///
  /// 手柄自己只有 44 点的触摸框，它的局部坐标不能代表手指落在正文哪儿；
  /// 这一层铺满正文区，用它的局部坐标才和矩形、正文区原点同一个坐标系。
  Offset _localOf(Offset global) {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return global;
    return box.globalToLocal(global);
  }

  void _finish() {
    widget.onDragEnd();
    if (_handle == null) return;
    setState(() => _handle = null);
  }

  /// 一端的落点：起点贴第一行左下、终点贴最后一行右下（由父级按页算好）
  Offset? _anchorOf(bool atEnd) =>
      atEnd ? widget.endAnchor : widget.startAnchor;
}

/// 手柄：一条竖线连到圆点（与简化模式同一个画法，两种排版手感一致）
class _HandlePainter extends CustomPainter {
  const _HandlePainter({required this.color, required this.atEnd});

  final Color color;
  final bool atEnd;

  @override
  void paint(Canvas canvas, Size size) {
    final fill = Paint()..color = color;
    final center = Offset(size.width / 2, kHandleCenterOffset);
    canvas.drawRect(
      Rect.fromLTRB(
        center.dx - 1,
        0,
        center.dx + 1,
        center.dy - kHandleRadius + 2,
      ),
      fill,
    );
    canvas.drawCircle(center, kHandleRadius, fill);
    canvas.drawCircle(
      center,
      kHandleRadius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = const Color(0xFFFFFFFF),
    );
  }

  @override
  bool shouldRepaint(_HandlePainter old) =>
      old.color != color || old.atEnd != atEnd;
}
