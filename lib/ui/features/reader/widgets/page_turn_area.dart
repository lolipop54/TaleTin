/// 翻页交互区（实现计划 S9）。
///
/// 点按与拖动共用所选效果；动画所需页面准备好后开始，结束才提交位置。
/// 交互口径（设计文档 2.4，分区比例见 [GtReadingTapZones]）：
/// - 左侧 35% 点击 → 上一页，右侧 35% 点击 → 下一页，中间 30% 点击 → 切控制栏；
/// - 仿真、平移与覆盖按最后明确的移动方向收尾；无动画保留距离和速度判定；
/// - 相邻页已排好时拖动过程中就能看到下一页，翻过去不等待排版；
/// - 相邻页还没排好（章首往回拖、刚跨章时上一章还在预取）时不推移画面，
///   先准备相邻页，再按所选效果补完翻页。
library;

import 'dart:ui' show FramePhase, FrameTiming;
import 'dart:async';
import '../../../../core/diagnostics/reader_turn_diagnostics.dart';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart' show kTouchSlop;
import '../../../../domain/models/reading_settings.dart';

import '../../../core/theme/gt_tokens.dart';
import 'fold_frames.dart';
import 'page_fold.dart';
import 'prepared_page.dart';
import 'prepared_page_view.dart';
import 'turn_trace.dart';
import 'turn_response_trace.dart';
import 'reader_drag_detector.dart';
import 'reader_turn_timing.dart';
import 'original_scroll_frames.dart';

part 'page_turn_input.dart';
part 'page_turn_logging.dart';

/// 翻页方向
enum PageTurnDirection { forward, backward }

class PageTurnArea extends StatefulWidget {
  /// PDF第二指按下时撤销尚未提交的翻页，后续移动交给缩放。
  static void cancelGesture(GlobalKey key) {
    final state = key.currentState;
    if (state is! _PageTurnAreaState || state._committing) return;
    state._pointerCancelled = true;
    state._ignorePointer = true;
    state._clearFold();
    state._controller.stop();
    state._dragAccepted = false;
    state._direction = null;
    state._neighbour = null;
    state._offset = state._dragged = 0;
    state._motion.value++;
  }
  static Future<void> turn(GlobalKey key, bool forward) async {
    final state = key.currentState;
    if (state is _PageTurnAreaState && !state._controller.isAnimating && !state._committing && !state._finishingInput) {
      await state._finishInput(() => state._tapTurn(
          forward ? PageTurnDirection.forward : PageTurnDirection.backward));
    }
  }
  const PageTurnArea({
    super.key,
    required this.currentPage,
    required this.previousPage,
    required this.nextPage,
    required this.turnId,
    required this.onTurn,
    required this.onCenterTap,
    this.prepareFold,
    this.effect = PageTurnEffect.curl,
    this.onTapIntercept,
    this.onManualStart,
    this.onGestureFinished,
    this.resolvePage,
    this.onInteractionStart,
    this.onSettling,
    this.traceLabel = 'simplified',
    this.inputRevision,
    this.inputAllowed,
    this.spread = false,
    this.slideImages = false,
  });

  /// 诊断日志里区分两套排版（简化 / 原书），只用于 GT_PROFILE_CAPTURE 采样。
  final String traceLabel;
  final bool spread;
  /// 原书平移使用整页截图；简化排版和PDF继续各自原有的页面交接。
  final bool slideImages;

  /// 当前页
  final Widget currentPage;
  final PageTurnEffect effect;
  final Future<bool> Function(Offset)? onTapIntercept;
  final VoidCallback? onManualStart;
  final FutureOr<void> Function()? onGestureFinished;
  /// 外部跳转或排版变化使未处理手势失效，正常翻页不改变此值。
  final Object? inputRevision;
  final bool Function()? inputAllowed;
  final Future<Widget?> Function(PageTurnDirection)? resolvePage;
  final VoidCallback? onInteractionStart;
  final void Function(PageTurnDirection)? onSettling;

  /// 相邻页（为空时不允许朝那个方向拖动，只能点击后等待排版）
  final Widget? previousPage;
  final Widget? nextPage;

  /// 当前页的标识（章节 + 页序）：变化即代表真的翻过去了
  final Object turnId;

  /// 提交翻页；返回 false 表示没有翻动（已在全书首尾）
  final Future<bool> Function(PageTurnDirection direction) onTurn;
  final VoidCallback onCenterTap;
  final Future<FoldFrames?> Function(PageTurnDirection)? prepareFold;

  @override
  State<PageTurnArea> createState() => _PageTurnAreaState();
}

class _PageTurnAreaState extends State<PageTurnArea>
    with TickerProviderStateMixin {
  /// 无动画翻页的距离阈值：页宽的 1/4。
  static const double _commitFraction = 0.25;

  /// 甩动判定速度（像素/秒）
  static const double _flingVelocity = 420;

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: readerTurnDuration,
  );

  /// 当前位移：向右为正
  double _offset = 0;
  // 拖动只更新动画子树，不让外层尺寸布局和手势识别器逐帧重建。
  final _motion = ValueNotifier<int>(0);
  // 原书截图（含横屏双页）拖动需要连续帧时钟，仿真也不能漏掉。
  // 避免触点恰好落在vsync后时再空等一帧；松手后由原动画接管。
  // 只调度帧；位移仍完全来自原有触点，绘制与动画规则不变。
  late final _dragFrames = OriginalScrollFrames(this);
  late final AppLifecycleListener _dragLifecycle;
  bool get _needsDragFrames => widget.slideImages &&
      (widget.effect == PageTurnEffect.curl ||
          widget.effect == PageTurnEffect.slide || widget.effect == PageTurnEffect.cover);

  /// 本次手势累计的横向位移（不做 clamp）；相邻页没排好时用它判定是否翻页
  double _dragged = 0;

  // 保留最后一段明确移动的方向；停住松手不丢失，微小反向抖动不改判。
  double _tailTravel = 0;
  double _releaseDirection = 0;

  /// 拖动中的方向；null 表示还没开始拖
  PageTurnDirection? _direction;

  /// 拖动/动画期间冻结的相邻页：提交那一刻不能跟着状态刷新跳页。
  /// 为 null 表示相邻页还没排好（章首往回拖、刚跨章时上一章还在预取）
  Widget? _neighbour;

  /// 提交中的翻页结果（用于避免重复提交）
  bool _committing = false;
  bool _dragAccepted = false;
  bool _pointerCancelled = false;
  FoldFrames? _fold;
  PreparedPage? _landing;
  Future<void>? _foldPending;
  int _foldToken = 0;
  bool _fromTop = false;
  bool _edgeCurl = false;
  double? _edgeOriginY;
  bool _settledTouch = false;
  Offset? _touchPosition;
  // 拖动中的几何完全由触点决定；进度只用于松手动画的两个端点。
  double _foldProgress = 0.5;
  bool _finishingInput = false, _ignorePointer = false;

  int? _pointer;
  final _responseTrace = TurnResponseTrace();
  ReaderTurnTrace? _turnLog;

  // 包括图片/链接判断和落页确认在内，一轮操作结束前不接受新操作。
  // 忙碌期间的新输入整轮忽略，不排队、不补翻。
  Future<void> _finishInput(Future<void> Function() action) async {
    if (_finishingInput) {
      traceTurn('input skipped reason=finishing $_traceInput');
      return;
    }
    _finishingInput = true;
    final responsePointer = _responseTrace.active;
    final turnLog = _turnLog;
    turnLog?.operationActive = true;
    turnLog?.event('input.action.begin');
    try {
      await traceTurnStep('input action pointer=$responsePointer', action);
      if (mounted) {
        await traceTurnStep('input end-of-frame $_traceInput',
            () => WidgetsBinding.instance.endOfFrame);
      }
    } finally {
      _responseTrace.finish(responsePointer);
      _finishingInput = false;
      turnLog?.operationActive = false;
      turnLog?.finish('inputReleased');
      traceTurn('input released $_traceInput');
    }
  }

  @override
  void initState() {
    super.initState();
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _dragFrames.setForeground(lifecycle == null || lifecycle == AppLifecycleState.resumed);
    _dragLifecycle = AppLifecycleListener(onStateChange: (state) =>
      _dragFrames.setForeground(state == AppLifecycleState.resumed));
    if (turnTraceEnabled || const bool.fromEnvironment('GT_PROFILE_CAPTURE') || const bool.fromEnvironment('GT_TRACE_FRAMES')) {
      WidgetsBinding.instance.addTimingsCallback(_profileFrames);
    }
  }

  void _profileFrames(List<FrameTiming> frames) {
    // 独立于逐触点日志采样，保留 vsync 时间，120Hz 下也能检查漏帧。
    // 每 12 帧一行，避免 Android 截断长日志；不额外请求渲染。
    if (const bool.fromEnvironment('GT_TRACE_FRAMES')) {
      for (var start = 0; start < frames.length; start += 12) {
        final batch = frames.skip(start).take(12);
        debugPrint('TURN_FRAME_TIMINGS ${widget.traceLabel} ${batch.map((f) => [
          f.timestampInMicroseconds(FramePhase.vsyncStart),
          f.buildDuration.inMicroseconds,
          f.rasterDuration.inMicroseconds,
          f.totalSpan.inMicroseconds,
        ]).toList()}');
      }
    }
    if (turnTraceEnabled) {
      for (final frame in frames) {
        if (frame.buildDuration.inMilliseconds >= 24 || frame.rasterDuration.inMilliseconds >= 24) {
          traceTurn('slow-frame $_traceInput buildUs=${frame.buildDuration.inMicroseconds} rasterUs=${frame.rasterDuration.inMicroseconds} totalUs=${frame.totalSpan.inMicroseconds}');
        }
      }
    }
    if (!const bool.fromEnvironment('GT_PROFILE_CAPTURE')) return;
    final label = widget.traceLabel;
    debugPrint('TURN_FRAMES $label ${frames.map((f) =>
      [f.buildDuration.inMicroseconds, f.rasterDuration.inMicroseconds]).toList()}');
  }

  void _clearFold() {
    _foldToken++;
    _landing?.dispose();
    _landing = null;
    _fold?.dispose();
    _fold = null;
    _foldPending = null;
    _touchPosition = null;
    _edgeCurl = false;
    _edgeOriginY = null;
    _settledTouch = false;
    _foldProgress = 0.5;
  }

  void _prepareFold(PageTurnDirection direction) {
    if (widget.effect == PageTurnEffect.none) return;
    final watch = Stopwatch()..start();
    final token = ++_foldToken;
    traceTurn('fold begin $_traceInput direction=$direction neighbour=${_neighbour != null}');
    // 分段计时：拖动开始到这一轮折页真正能画出来之间的每一段等待分别记多久。
    // 只统计已有步骤，不额外截图、不额外等待；正式包不采集。
    var mark = watch.elapsedMicroseconds;
    void stage(String name) {
      final now = watch.elapsedMicroseconds;
      readerPerf('${widget.traceLabel}.${widget.effect.name}.$name', now - mark,
          {'totalUs': now, 'token': token});
      traceTurn('fold stage=$name pointer=${_responseTrace.active} mode=${widget.traceLabel} token=$token '
          'stageUs=${now - mark} totalUs=$now');
      if (const bool.fromEnvironment('GT_PROFILE_CAPTURE')) {
        debugPrint('TURN_STAGE ${widget.traceLabel} $name ${now - mark}us at=${now}us');
      }
      mark = now;
    }
    _foldPending = () async {
      final neighbour = _neighbour ?? await widget.resolvePage?.call(direction);
      stage('resolve');
      if (!mounted || token != _foldToken) {
        traceTurn('fold discarded stage=resolve token=$token $_traceInput mounted=$mounted');
        return;
      }
      _neighbour = neighbour;
      if (neighbour == null) {
        traceTurn('fold no-neighbour $_traceInput');
        return;
      }
      final frames = await widget.prepareFold?.call(direction);
      stage('prepare');
      if (!mounted || token != _foldToken) {
        traceTurn('fold discarded stage=prepare token=$token $_traceInput mounted=$mounted');
        frames?.dispose(); return;
      }
      if (widget.effect == PageTurnEffect.curl || widget.effect == PageTurnEffect.cover) {
        frames?.preparePainting(context.size!, MediaQuery.devicePixelRatioOf(context),
            backward: direction == PageTurnDirection.backward,
            // 覆盖只平移整页图，不使用卷曲网格的裁剪图。
            curl: widget.effect == PageTurnEffect.curl);
      }
      stage('paint');
      setState(() => _fold = frames);
      if (const bool.fromEnvironment('GT_PROFILE_CAPTURE')) {
        debugPrint('TURN_READY ${widget.traceLabel} ${watch.elapsedMicroseconds}us');
      }
    }();
  }

  @override
  void didUpdateWidget(PageTurnArea oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 真的翻过去了：清掉冻结的相邻页与位移，回到稳定态
    if (oldWidget.inputRevision != widget.inputRevision ||
        oldWidget.effect != widget.effect ||
        (oldWidget.turnId != widget.turnId && !_committing && !_finishingInput)) {
      traceTurn('input invalidated $_traceInput oldTurn=${oldWidget.turnId} '
          'revisionChanged=${oldWidget.inputRevision != widget.inputRevision} '
          'effectChanged=${oldWidget.effect != widget.effect}');
      _ignorePointer = true;
      _dragFrames.stop();
      _clearFold();
    }
    if (oldWidget.turnId != widget.turnId || oldWidget.effect != widget.effect ||
        oldWidget.inputRevision != widget.inputRevision) {
      traceTurn('reset $_traceInput oldTurn=${oldWidget.turnId} commit=$_committing');
      final landing = _committing ? _fold?.preparedTarget?.clone() : null;
      _clearFold();
      _landing = landing;
      _controller.stop();
      _committing = false;
      _dragAccepted = false;
      _direction = null;
      _neighbour = null;
      _offset = 0;
      _dragged = 0;
    }
  }

  @override
  void dispose() {
    _dragLifecycle.dispose();
    _dragFrames.dispose();
    if (turnTraceEnabled || const bool.fromEnvironment('GT_PROFILE_CAPTURE') || const bool.fromEnvironment('GT_TRACE_FRAMES')) {
      WidgetsBinding.instance.removeTimingsCallback(_profileFrames);
    }
    _clearFold();

    _controller.dispose();
    _motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 页宽只能在布局回调里拿到（build 期间取 context.size 会直接抛错），
    // 因此这里用 LayoutBuilder 把尺寸交给手势回调
    // 拖动 setState 会连同 LayoutBuilder 重新布局。边界必须包住整个
    // 交互区，只包 CustomPaint 仍会把布局引起的重绘传到静止阅读层。
    return RepaintBoundary(child: LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width;
        return _buildInput(width);
      },
    ));
  }

  Widget _buildStack(double width) {
    if (_offset.abs() > 0.1 && (_fold != null ||
        (widget.prepareFold == null && _neighbour != null))) {
      _responseTrace.changedFrame(widget.traceLabel);
    }
    if (widget.effect == PageTurnEffect.none) return widget.currentPage;
    // 三种动画统一交接完整正文：动画中复用当前图，落页时接收目标图。
    // 各分支只负责几何画法，不能各自决定是否重新加载正文图片。
    final current = RepaintBoundary(child: PreparedPageTransfer(
        page: _landing ?? _fold?.preparedCurrent, child: widget.currentPage));
    // 原书平移复用已经确认的原尺寸截图。两页一起移动，不能套用底页不动的覆盖画法。
    // 没准备好时仍显示旧页；拖动期间不再逐次等待 WebView 执行位移。
    if (widget.slideImages && widget.effect == PageTurnEffect.slide &&
        _fold?.hasPageImages == true) {
      return CustomPaint(
        willChange: true,
        painter: SlideFramesPainter(
          _fold!, _offset, _direction == PageTurnDirection.backward),
      );
    }
    if ((widget.effect == PageTurnEffect.curl || widget.effect == PageTurnEffect.cover) &&
        widget.prepareFold != null) {
      final frames = _fold;
      return Stack(fit: StackFit.expand, children: [
        current,
        // 连续变化的卷页无需让引擎尝试缓存每一帧不同的绘制结果。
        if (frames != null) CustomPaint(
            willChange: true,
            painter: widget.effect == PageTurnEffect.cover
            ? CoverFramesPainter(frames, _offset, _direction == PageTurnDirection.backward)
            : FoldFramesPainter(
          frames, _foldProgress, _direction == PageTurnDirection.backward, _fromTop,
          touchPosition: _touchPosition, edgeCurl: _edgeCurl,
          edgeOriginY: _edgeOriginY, settledTouch: _settledTouch)),
      ]);
    }
    final neighbour = _neighbour;
    if (neighbour == null && widget.effect != PageTurnEffect.slide) {
      return current;
    }

    final forward = _direction == PageTurnDirection.forward;
    if (widget.effect == PageTurnEffect.cover) {
      // 未使用图片缓存的调用方也遵循同一覆盖顺序，底页始终不动。
      return Stack(fit: StackFit.expand, children: [
        forward ? neighbour! : current,
        Positioned(left: forward ? _offset : _offset - width, top: 0,
          bottom: 0, width: width,
          child: forward ? current : neighbour!),
      ]);
    }
    // 和卷页一样，图片未准备好时保留整张旧页，不能先推开正文露出空白。
    final showNeighbour = neighbour != null &&
        (widget.prepareFold == null || _fold != null);
    return Stack(
      children: [
        if (showNeighbour) Positioned(
          key: const ValueKey('neighbour-page'),
          left: 0,
          top: 0,
          width: width,
          bottom: 0,
          child: Transform.translate(
            offset: Offset(forward ? width + _offset : _offset - width, 0),
            child: RepaintBoundary(child: PreparedPageTransfer(
              page: _fold?.preparedTarget, child: neighbour))),
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
            offset: Offset(showNeighbour ? _offset : 0, 0), child: current),
        ),
      ],
    );
  }

  Future<void> _onTapUp(TapUpDetails details, double width) async {
    if (_committing || _controller.isAnimating) return;
    final token = _foldToken;
    if (await traceTurnStep('tap hit-test', () async =>
        await widget.onTapIntercept?.call(details.localPosition) ?? false) || !mounted) { return; }
    if (token != _foldToken || _committing || _controller.isAnimating) return;
    final dx = details.localPosition.dx;
    if (dx < width * GtReadingTapZones.previousEdge) {
      await _tapTurn(PageTurnDirection.backward, position: details.localPosition);
    } else if (dx > width * GtReadingTapZones.nextEdge) {
      await _tapTurn(PageTurnDirection.forward, position: details.localPosition);
    } else {
      widget.onCenterTap();
    }
  }

  /// 点按使用与拖动相同的准备、动画和提交顺序。
  Future<void> _tapTurn(PageTurnDirection direction, {Offset? position}) async {
    if (_committing) return;
    final size = context.size!;
    final backward = direction == PageTurnDirection.backward;
    _onDragStart(DragStartDetails(localPosition:
        position ?? Offset(backward ? 0 : size.width, size.height / 2)));
    _dragAccepted = false;
    _committing = true;
    _direction = direction;
    _neighbour = backward ? widget.previousPage : widget.nextPage;
    if (widget.effect != PageTurnEffect.none) {
      _touchPosition = Offset(widget.spread ? _foldSize.width : backward ? -size.width : size.width,
          _edgeCurl ? _edgeOriginY! : (_fromTop ? 0 : size.height));
      _foldProgress = 0;
      _settledTouch = true; // 点按已给出完整端点，不再当成手指拖动约束。
      _prepareFold(direction);
      final token = _foldToken;
      await _foldPending;
      if (!mounted || token != _foldToken) return;
      if (_neighbour != null) {
        widget.onSettling?.call(direction);
        await traceTurnStep('tap animation', () => _animateTo(backward ? size.width : -size.width,
            tap: true,
            cornerTap: widget.effect == PageTurnEffect.curl && !_edgeCurl));
      }
      if (!mounted || token != _foldToken) return;
    }
    final moved = await traceTurnStep('tap commit', () => widget.onTurn(direction));
    if (!mounted) return;
    if (!moved) {
      await widget.onGestureFinished?.call();
      if (!mounted) return;
      setState(() {
        _committing = false;
        _clearFold(); _neighbour = null;
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
    _edgeCurl = details.localPosition.dy >= height / 3 &&
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
      _direction =
          forward ? PageTurnDirection.forward : PageTurnDirection.backward;
      // 相邻页可能还没排好：这时不推移画面，手势照常走完，
      // 松手按累计位移与甩动判定是否翻页（章首往回拖不会再没反应）
      _neighbour = forward ? widget.nextPage : widget.previousPage;
      if (!forward && widget.effect == PageTurnEffect.curl) {
        // 回翻手势统一抓住书页中部，上下起手都不切到折角模式。
        _edgeCurl = true;
        _edgeOriginY = context.size!.height / 2;
      }
      _prepareFold(_direction!);
    }
    if (delta != 0) {
      _tailTravel = _tailTravel.sign == delta.sign ? _tailTravel + delta : delta;
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
        ? Offset(forward ? details.localPosition.dx - width / 2 : width / 2 - details.localPosition.dx, _edgeCurl ? _edgeOriginY! : details.localPosition.dy)
        : !forward && widget.effect == PageTurnEffect.curl
        ? Offset(details.localPosition.dx, _edgeOriginY!) : details.localPosition;
    // 回翻覆盖页的右边缘直接跟随触点，不能只累计起手后的位移。
    final shift = widget.effect == PageTurnEffect.cover && !forward
        ? details.localPosition.dx : _offset + delta;
    _offset = shift.clamp(forward ? -width : 0, forward ? 0 : width);
    if (widget.spread && _touchPosition != null) {
      final leaf = _foldSize;
      final corner = Offset(leaf.width, _edgeCurl ? _edgeOriginY! : _fromTop ? 0 : leaf.height);
      _touchPosition = PageFold.dragTouch(leaf, corner, _touchPosition!, backward: false, edgeCurl: _edgeCurl);
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
    await traceTurnStep('drag wait-fold $_traceInput', () async => await _foldPending);
    if (!mounted || pendingToken != _foldToken) {
      traceTurn('drag end discarded token=$pendingToken $_traceInput mounted=$mounted');
      return;
    }
    traceTurn('dragEnd ready $_traceInput fold=${_fold != null} distance=$_dragged cancelled=$cancelled');
    _committing = false;
    final forward = direction == PageTurnDirection.forward;
    final velocity = details.velocity.pixelsPerSecond.dx;
    // 有相邻页时看推移后的位移，没相邻页时看手势累计位移
    final shift = _neighbour == null ||
        (widget.effect == PageTurnEffect.cover && !forward) ? _dragged : _offset;
    // 有动画时按最后明确方向收尾；只有无动画仍判断距离和速度。
    final committed = !cancelled && (widget.effect != PageTurnEffect.none
        ? (_releaseDirection == (forward ? -1 : 1))
        : forward
        ? (-shift > width * _commitFraction || velocity < -_flingVelocity)
        : (shift > width * _commitFraction || velocity > _flingVelocity));
    if (const bool.fromEnvironment('GT_PROFILE_CAPTURE')) {
      debugPrint('TURN_RELEASE direction=$direction tail=$_tailTravel '
          'release=$_releaseDirection distance=$_dragged velocity=$velocity '
          'cancelled=$cancelled commit=$committed');
    }

    traceTurn('decision $_traceInput direction=$direction commit=$committed velocity=$velocity release=$_releaseDirection shift=$shift width=$width');
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
      setState(() {
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
    final moved = await traceTurnStep('drag commit $_traceInput', () => widget.onTurn(direction));
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
      setState(() {
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
    setState(() {
      _committing = false;
      _clearFold();

      _direction = null;
      _neighbour = null;
    });
  }

  Size get _foldSize => widget.spread ? Size(context.size!.width / 2, context.size!.height) : context.size!;

  Future<void> _animateTo(double target, {bool cornerTap = false, bool tap = false}) {
    final turnLog = _turnLog;
    turnLog?.event('animation.begin', [_offset, target, tap, cornerTap]);
    final watch = readerPerformanceEnabled ? (Stopwatch()..start()) : null;
    final from = _offset;
    final progressFrom = _foldProgress;
    final size = _foldSize;
    final fromLeft = !widget.spread && _direction == PageTurnDirection.backward;
    final corner = Offset(size.width,
        _edgeCurl ? _edgeOriginY! : (_fromTop ? 0 : size.height));
    // 从已经受书脊限制的纸边出发，一直补到完整展开或移出屏幕。
    final touchFrom = _touchPosition == null ? corner : _settledTouch
        ? _touchPosition! : PageFold.dragTouch(size, corner, _touchPosition!,
            backward: fromLeft, edgeCurl: _edgeCurl);
    final unfolded = fromLeft ? target != 0 : target == 0;
    final touchTo = Offset(unfolded ? size.width : -size.width, corner.dy);
    _settledTouch = true;
    final curve = CurvedAnimation(parent: _controller, curve: cornerTap ? Curves.easeInOutCubic : Curves.easeOutCubic);
    final animation = Tween<double>(begin: from, end: target).animate(
      curve,
    );
    void listener() {
      if (!mounted) return;
      _offset = animation.value;
      _touchPosition = cornerTap
          ? PageFold.tapCornerTouch(size, curve.value,
              backward: fromLeft, fromTop: _fromTop)
          : PageFold.settleTouch(touchFrom, touchTo, curve.value, unfolded: unfolded);
      _foldProgress = progressFrom + ((target == 0 ? 0 : 1) - progressFrom) * curve.value;
      _motion.value++;
      turnLog?.event('animation.tick', [_controller.value, _offset]);
    }

    _controller
      ..stop()
      ..duration = readerTurnDuration
      ..reset()
      ..addListener(listener);
    traceTurn('animation begin $_traceInput from=$from target=$target '
        'durationMs=${_controller.duration?.inMilliseconds} tap=$tap');
    return _controller.forward().orCancel.catchError((Object error) {
      if (error is! TickerCanceled) throw error;
    }).whenComplete(() {
      turnLog?.event('animation.end', [_controller.value]);
      if (watch != null) {
        readerPerf('${widget.traceLabel}.${widget.effect.name}.animation',
            watch.elapsedMicroseconds, {'cancelled': _controller.value < 1});
      }
      traceTurn('animation end $_traceInput value=${_controller.value}');
      _controller.removeListener(listener);
      curve.dispose();
    });
  }
}
