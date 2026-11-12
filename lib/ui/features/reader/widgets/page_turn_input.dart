part of 'page_turn_area.dart';

extension _PageTurnInput on _PageTurnAreaState {
  /// 无动画翻页的距离阈值：页宽的 1/4。
  static const double _commitFraction = 0.25;

  /// 甩动判定速度（像素/秒）。
  static const double _flingVelocity = 420;

  String? _inputBlockReason() {
    if (_finishingInput) return 'finishing';
    if (_committing) return 'committing';
    if (_controller.isAnimating) return 'animating';
    if (!(widget.inputAllowed?.call() ?? true)) return 'pageNotReady';
    return null;
  }

  String get _traceInput =>
      'pointer=$_pointer active=${_responseTrace.active} mode=${widget.traceLabel} '
      'turn=${widget.turnId} effect=${widget.effect.name} ignore=$_ignorePointer '
      'accepted=$_dragAccepted busy=$_finishingInput/$_committing token=$_foldToken';

  void _tracePointer(PointerEvent event) {
    if (!turnTraceEnabled) return;
    traceTurnSample('raw-${event.pointer}', [
      event.runtimeType.toString(),
      event.timeStamp.inMicroseconds,
      event.position.dx,
      event.position.dy,
      event.localPosition.dx,
      event.localPosition.dy,
      event.delta.dx,
      event.delta.dy,
    ]);
    if (event is PointerUpEvent || event is PointerCancelEvent) {
      traceTurnFlush('raw-${event.pointer}');
      traceTurnFlush('drag-${event.pointer}');
      traceTurn(
        'pointer end $_traceInput cancelled=${event is PointerCancelEvent}',
      );
    }
  }

  Widget _buildInput(double width) => Listener(
    onPointerDown: (event) {
      _tracePointer(event);
      _pointer = event.pointer;
      _responseTrace.begin(event.pointer, event.timeStamp);
      // 按下时决定整轮是否接收。忙碌中起手即使拖到空闲，也不能半途接管。
      final blockReason = _inputBlockReason();
      _ignorePointer = blockReason != null;
      _observePointerDown(event.pointer, blockReason);
      _logPointerDown(event);
      _stallEvent('pointer.down', {
        'pointer': event.pointer,
        'blockReason': blockReason,
      });
      traceTurn('down $_traceInput animating=${_controller.isAnimating}');
      if (_ignorePointer) {
        readerPerf('${widget.traceLabel}.${widget.effect.name}.ignored', 0);
        return;
      }
      _pointerCancelled = false;
      if (_needsDragFrames) _dragFrames.motion();
      _responseTrace.activate(_pointer);
      widget.onInteractionStart?.call();
    },
    onPointerMove: (event) {
      if (!_ignorePointer && _needsDragFrames) _dragFrames.motion();
      _responseTrace.move(event.pointer, event.timeStamp);
      _tracePointer(event);
    },
    onPointerUp: (event) {
      _dragFrames.stop();
      _tracePointer(event);
      _stallEvent('pointer.up', {'pointer': event.pointer});
    },
    onPointerCancel: (event) {
      _dragFrames.stop();
      _tracePointer(event);
      _stallEvent('pointer.cancel', {'pointer': event.pointer});
      if (!_ignorePointer) _pointerCancelled = true;
    },
    child: ReaderDragDetector(
      onTapUp: (details) {
        _stallEvent('gesture.tap');
        if (!_ignorePointer) _turnLog?.event('gesture.tap');
        if (!_ignorePointer) _finishInput(() => _onTapUp(details, width));
      },
      onHorizontalDragStart: (details) {
        _stallEvent('gesture.drag.start');
        if (!_ignorePointer) {
          _turnLog?.operationActive = true;
          _turnLog?.event('gesture.drag');
        }
        _responseTrace.recognized(_pointer);
        traceTurn('recognizer start $_traceInput');
        if (!_ignorePointer) _onDragStart(details);
      },
      onHorizontalDragUpdate: (details) {
        if (!_ignorePointer) _logDrag(details);
        if (turnTraceEnabled) {
          traceTurnSample('drag-$_pointer', [
            details.sourceTimeStamp?.inMicroseconds,
            details.localPosition.dx,
            details.localPosition.dy,
            details.delta.dx,
            details.delta.dy,
            _ignorePointer,
            _dragAccepted,
          ]);
        }
        if (!_ignorePointer) _onDragUpdate(details, width);
      },
      onHorizontalDragEnd: (details) {
        _stallEvent('gesture.drag.end');
        traceTurnFlush('drag-$_pointer');
        traceTurn('recognizer end $_traceInput distance=$_dragged');
        if (!_ignorePointer && _dragAccepted) {
          _finishInput(() => _onDragEnd(details, width));
        }
      },
      onHorizontalDragCancel: () {
        _stallEvent('gesture.drag.cancel');
        traceTurnFlush('drag-$_pointer');
        traceTurn('recognizer cancel $_traceInput');
        if (!_ignorePointer && _dragAccepted) {
          _finishInput(() => _onDragCancel(width));
        }
      },
      child: ClipRect(
        child: ValueListenableBuilder<int>(
          valueListenable: _motion,
          builder: (context, value, child) => _buildStack(width),
        ),
      ),
    ),
  );

  Future<void> _onTapUp(TapUpDetails details, double width) async {
    if (_committing || _controller.isAnimating) return;
    final token = _foldToken;
    if (await _tracePageStep(
          'tap hit-test',
          () async =>
              await widget.onTapIntercept?.call(details.localPosition) ?? false,
        ) ||
        !mounted) {
      return;
    }
    if (token != _foldToken || _committing || _controller.isAnimating) return;
    final dx = details.localPosition.dx;
    if (dx < width * GtReadingTapZones.previousEdge) {
      await _tapTurn(
        PageTurnDirection.backward,
        position: details.localPosition,
      );
    } else if (dx > width * GtReadingTapZones.nextEdge) {
      await _tapTurn(
        PageTurnDirection.forward,
        position: details.localPosition,
      );
    } else {
      widget.onCenterTap();
    }
  }

  /// 点按使用与拖动相同的准备、动画和提交顺序。
  Future<void> _tapTurn(PageTurnDirection direction, {Offset? position}) async {
    if (_committing) return;
    final size = context.size!;
    final backward = direction == PageTurnDirection.backward;
    _onDragStart(
      DragStartDetails(
        localPosition:
            position ?? Offset(backward ? 0 : size.width, size.height / 2),
      ),
    );
    _dragAccepted = false;
    _committing = true;
    _direction = direction;
    _neighbour = backward ? widget.previousPage : widget.nextPage;
    if (widget.effect != PageTurnEffect.none) {
      _touchPosition = Offset(
        widget.spread
            ? _foldSize.width
            : backward
            ? -size.width
            : size.width,
        _edgeCurl ? _edgeOriginY! : (_fromTop ? 0 : size.height),
      );
      _foldProgress = 0;
      _settledTouch = true; // 点按已给出完整端点，不再当成手指拖动约束。
      _prepareFold(direction);
      final token = _foldToken;
      await _foldPending;
      if (!mounted || token != _foldToken) return;
      if (_neighbour != null) {
        widget.onSettling?.call(direction);
        await _tracePageStep(
          'tap animation',
          () => _animateTo(
            backward ? size.width : -size.width,
            tap: true,
            cornerTap: widget.effect == PageTurnEffect.curl && !_edgeCurl,
          ),
        );
      }
      if (!mounted || token != _foldToken) return;
    }
    final moved = await _tracePageStep(
      'tap commit',
      () => widget.onTurn(direction),
    );
    if (!mounted) return;
    if (!moved) {
      await widget.onGestureFinished?.call();
      if (!mounted) return;
      _updateTurn(() {
        _committing = false;
        _clearFold();
        _neighbour = null;
      });
    }
    // 成功时保留提交状态，等 didUpdateWidget 把目标图片交给静态页再释放。
    // 提前清掉会让含图页重新异步加载，在动画末尾闪回旧页一帧。
  }

  void _onDragStart(DragStartDetails details) {
    // 没有接收起手时忽略整轮事件，不在旧动画结束后半途接管。
    _dragAccepted = !_committing && !_controller.isAnimating;
    traceTurn('dragStart accepted=$_dragAccepted');
    if (!_dragAccepted) return;
    widget.onManualStart?.call();
    _clearFold();
    _offset = 0;
    _fromTop = details.localPosition.dy < context.size!.height / 2;
    // 按起手位置固定模式，拖过分区边界时不突然切换形状。
    final height = context.size!.height;
    _edgeCurl =
        details.localPosition.dy >= height / 3 &&
        details.localPosition.dy <= height * 2 / 3;
    _touchPosition = details.localPosition;
    _edgeOriginY = details.localPosition.dy;
    _direction = null;
    _neighbour = null;
    _dragged = 0;
    _tailTravel = 0;
    _releaseDirection = 0;
  }

  void _onDragUpdate(DragUpdateDetails details, double width) {
    if (!_dragAccepted || _committing || _controller.isAnimating) return;
    final delta = details.delta.dx;
    if (delta == 0 && _direction == null) return;
    if (_direction == null) {
      final forward = delta < 0;
      _direction = forward
          ? PageTurnDirection.forward
          : PageTurnDirection.backward;
      // 相邻页可能还没排好：这时不推移画面，手势照常走完，
      // 松手按累计位移与甩动判定是否翻页（章首往回拖不会再没反应）
      _neighbour = forward ? widget.nextPage : widget.previousPage;
      if (!widget.spread && !forward && widget.effect == PageTurnEffect.curl) {
        // 单页回翻从纸边中部展开。双页由绘制层镜像左页，沿用起手时的书角或纸边。
        _edgeCurl = true;
        _edgeOriginY = context.size!.height / 2;
      }
      _prepareFold(_direction!);
    }
    if (delta != 0) {
      _tailTravel = _tailTravel.sign == delta.sign
          ? _tailTravel + delta
          : delta;
      // 拖动已通过手势识别；首次移动给出方向。改判必须明确拖回，
      // 使用 Flutter 的触摸容差，避免抬指时数像素的反向抖动造成回弹。
      if (_releaseDirection == 0 || _tailTravel.abs() >= kTouchSlop) {
        _releaseDirection = _tailTravel.sign;
      }
    }
    _dragged += delta;
    final forward = _direction == PageTurnDirection.forward;
    // localPosition 保留实际纵坐标，纯上下移动也更新折角。
    _touchPosition = widget.spread
        ? Offset(
            forward
                ? details.localPosition.dx - width / 2
                : width / 2 - details.localPosition.dx,
            _edgeCurl ? _edgeOriginY! : details.localPosition.dy,
          )
        : !forward && widget.effect == PageTurnEffect.curl
        ? Offset(details.localPosition.dx, _edgeOriginY!)
        : details.localPosition;
    // 回翻覆盖页的右边缘直接跟随触点，不能只累计起手后的位移。
    final shift = widget.effect == PageTurnEffect.cover && !forward
        ? details.localPosition.dx
        : _offset + delta;
    _offset = shift.clamp(forward ? -width : 0, forward ? 0 : width);
    // 双页书角可以拖过书沟直到对侧。中部卷边仍沿用固定起手高度的约束。
    if (widget.spread && !_followsSpreadCorner && _touchPosition != null) {
      final leaf = _foldSize;
      final corner = Offset(
        leaf.width,
        _edgeCurl
            ? _edgeOriginY!
            : _fromTop
            ? 0
            : leaf.height,
      );
      _touchPosition = PageFold.dragTouch(
        leaf,
        corner,
        _touchPosition!,
        backward: false,
        edgeCurl: _edgeCurl,
      );
    }
    _motion.value++;
  }

  Future<void> _onDragEnd(DragEndDetails details, double width) async {
    if (!_dragAccepted || _committing) {
      traceTurn('drag end skipped $_traceInput');
      return;
    }
    _dragAccepted = false;
    final direction = _direction;
    if (direction == null) {
      traceTurn('drag end skipped reason=no-direction $_traceInput');
      return;
    }
    _committing = true;
    final pendingToken = _foldToken;
    final cancelled = _pointerCancelled;
    await _tracePageStep(
      'drag wait-fold $_traceInput',
      () async => await _foldPending,
    );
    if (!mounted || pendingToken != _foldToken) {
      traceTurn(
        'drag end discarded token=$pendingToken $_traceInput mounted=$mounted',
      );
      return;
    }
    traceTurn(
      'dragEnd ready $_traceInput fold=${_fold != null} distance=$_dragged cancelled=$cancelled',
    );
    _committing = false;
    final forward = direction == PageTurnDirection.forward;
    final velocity = details.velocity.pixelsPerSecond.dx;
    // 有相邻页时看推移后的位移，没相邻页时看手势累计位移
    final shift =
        _neighbour == null ||
            (widget.effect == PageTurnEffect.cover && !forward)
        ? _dragged
        : _offset;
    // 有动画时按最后明确方向收尾；只有无动画仍判断距离和速度。
    final committed =
        !cancelled &&
        (widget.effect != PageTurnEffect.none
            ? (_releaseDirection == (forward ? -1 : 1))
            : forward
            ? (-shift > width * _commitFraction || velocity < -_flingVelocity)
            : (shift > width * _commitFraction || velocity > _flingVelocity));
    if (const bool.fromEnvironment('GT_PROFILE_CAPTURE')) {
      debugPrint(
        'TURN_RELEASE direction=$direction tail=$_tailTravel '
        'release=$_releaseDirection distance=$_dragged velocity=$velocity '
        'cancelled=$cancelled commit=$committed',
      );
    }

    traceTurn(
      'decision $_traceInput direction=$direction commit=$committed velocity=$velocity release=$_releaseDirection shift=$shift width=$width',
    );
    if (widget.effect == PageTurnEffect.none || _neighbour == null) {
      // 没有可推移的相邻页：不做过渡动画，直接提交（翻页后的排版结果上屏）
      _direction = null;
      _dragged = 0;
      if (committed) await _tapTurn(direction);
      return;
    }

    if (!committed) {
      _committing = true;
      final token = _foldToken;
      await _foldPending;
      if (!mounted || token != _foldToken) return;
      await _animateTo(0);
      if (!mounted) return;
      await widget.onGestureFinished?.call();
      if (!mounted) return;
      _updateTurn(() {
        _committing = false;
        _clearFold();

        _direction = null;
        _neighbour = null;
      });
      return;
    }

    _committing = true;
    final token = _foldToken;
    await _foldPending;
    if (!mounted || token != _foldToken) return;
    widget.onSettling?.call(direction);
    await _animateTo(forward ? -width : width);
    if (!mounted || token != _foldToken) return;
    final moved = await _tracePageStep(
      'drag commit $_traceInput',
      () => widget.onTurn(direction),
    );
    traceTurn('drag commit-result moved=$moved $_traceInput');
    // 目录／搜索跳转或提交期间的重建可能已清掉本次折页；旧手势不能再回弹。
    if (!mounted || token != _foldToken) return;
    if (!moved) {
      // 到边界了：弹回原位
      _committing = false;
      await _animateTo(0);
      if (!mounted) return;
      await widget.onGestureFinished?.call();
      if (!mounted) return;
      _updateTurn(() {
        _clearFold();

        _direction = null;
        _neighbour = null;
      });
    }
    // 翻页成功时等 didUpdateWidget 检测到 turnId 变化再复位
  }

  Future<void> _onDragCancel(double width) async {
    if (!_dragAccepted || _direction == null || _committing) return;
    _dragAccepted = false;
    _committing = true;
    _dragged = 0;
    final token = _foldToken;
    await _foldPending;
    if (!mounted || token != _foldToken) return;
    await _animateTo(0);
    if (!mounted) return;
    await widget.onGestureFinished?.call();
    if (!mounted) return;
    _updateTurn(() {
      _committing = false;
      _clearFold();

      _direction = null;
      _neighbour = null;
    });
  }
}
