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
import '../../../../core/diagnostics/reader_turn_state_diagnostics.dart';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart' show kTouchSlop;

import '../../../../domain/models/reading_settings.dart';
import '../../../../engine/layout/chapter_layout.dart' show LayoutCancelled;

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
part 'page_turn_state_logging.dart';

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
    if (state is _PageTurnAreaState &&
        !state._controller.isAnimating &&
        !state._committing &&
        !state._finishingInput) {
      await state._finishInput(
        () => state._tapTurn(
          forward ? PageTurnDirection.forward : PageTurnDirection.backward,
        ),
      );
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
  bool get _needsDragFrames =>
      widget.slideImages &&
      (widget.effect == PageTurnEffect.curl ||
          widget.effect == PageTurnEffect.slide ||
          widget.effect == PageTurnEffect.cover);

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
  int _stallPageRevision = 0;
  Timer? _blockedInputCheck;
  bool _reportedBlockedInput = false;

  // 包括图片/链接判断和落页确认在内，一轮操作结束前不接受新操作。
  // 忙碌期间的新输入整轮忽略，不排队、不补翻。
  Future<void> _finishInput(Future<void> Function() action) async {
    if (_finishingInput) {
      _stallEvent('action.skipped');
      traceTurn('input skipped reason=finishing $_traceInput');
      return;
    }
    _finishingInput = true;
    _stallEvent('action.begin');
    final responsePointer = _responseTrace.active;
    final turnLog = _turnLog;
    turnLog?.operationActive = true;
    turnLog?.event('input.action.begin');
    final revision = (_stallPageRevision, widget.inputRevision, widget.effect);
    try {
      await _tracePageStep('input action pointer=$responsePointer', action);
      if (mounted) {
        await _tracePageStep(
          'input end-of-frame $_traceInput',
          () => WidgetsBinding.instance.endOfFrame,
        );
      }
    } catch (error) {
      // 目标页尚未交接时结束这轮手势，保留原来的静态页。
      // 如果跳转已经换页，旧手势不能重置新页面的状态。
      if (mounted &&
          revision ==
              (_stallPageRevision, widget.inputRevision, widget.effect)) {
        setState(_resetTurn);
        await widget.onGestureFinished?.call();
      }
      if (error is! LayoutCancelled) rethrow;
    } finally {
      _responseTrace.finish(responsePointer);
      _finishingInput = false;
      turnLog?.operationActive = false;
      turnLog?.finish('inputReleased');
      _stallEvent('action.end');
      traceTurn('input released $_traceInput');
    }
  }

  @override
  void initState() {
    super.initState();
    ReaderTurnStateDiagnostics.attach(
      this,
      'pageTurn',
      _stallState,
      observeStalls: _observeStalls,
    );
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _dragFrames.setForeground(
      lifecycle == null || lifecycle == AppLifecycleState.resumed,
    );
    _dragLifecycle = AppLifecycleListener(
      onStateChange: (state) =>
          _dragFrames.setForeground(state == AppLifecycleState.resumed),
    );
    if (turnTraceEnabled ||
        const bool.fromEnvironment('GT_PROFILE_CAPTURE') ||
        const bool.fromEnvironment('GT_TRACE_FRAMES')) {
      WidgetsBinding.instance.addTimingsCallback(_profileFrames);
    }
  }

  void _profileFrames(List<FrameTiming> frames) {
    // 独立于逐触点日志采样，保留 vsync 时间，120Hz 下也能检查漏帧。
    // 每 12 帧一行，避免 Android 截断长日志；不额外请求渲染。
    if (const bool.fromEnvironment('GT_TRACE_FRAMES')) {
      for (var start = 0; start < frames.length; start += 12) {
        final batch = frames.skip(start).take(12);
        debugPrint(
          'TURN_FRAME_TIMINGS ${widget.traceLabel} ${batch.map((f) => [f.timestampInMicroseconds(FramePhase.vsyncStart), f.buildDuration.inMicroseconds, f.rasterDuration.inMicroseconds, f.totalSpan.inMicroseconds]).toList()}',
        );
      }
    }
    if (turnTraceEnabled) {
      for (final frame in frames) {
        if (frame.buildDuration.inMilliseconds >= 24 ||
            frame.rasterDuration.inMilliseconds >= 24) {
          traceTurn(
            'slow-frame $_traceInput buildUs=${frame.buildDuration.inMicroseconds} rasterUs=${frame.rasterDuration.inMicroseconds} totalUs=${frame.totalSpan.inMicroseconds}',
          );
        }
      }
    }
    if (!const bool.fromEnvironment('GT_PROFILE_CAPTURE')) return;
    final label = widget.traceLabel;
    debugPrint(
      'TURN_FRAMES $label ${frames.map((f) => [f.buildDuration.inMicroseconds, f.rasterDuration.inMicroseconds]).toList()}',
    );
  }

  void _clearFold() {
    _stallEvent('fold.clear');
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

  void _resetTurn({PreparedPage? landing}) {
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

  void _updateTurn(VoidCallback update) => setState(update);

  void _prepareFold(PageTurnDirection direction) {
    if (widget.effect == PageTurnEffect.none) return;
    final watch = Stopwatch()..start();
    final token = ++_foldToken;
    _stallEvent('fold.begin', {'direction': direction.name});
    traceTurn(
      'fold begin $_traceInput direction=$direction neighbour=${_neighbour != null}',
    );
    // 分段计时：拖动开始到这一轮折页真正能画出来之间的每一段等待分别记多久。
    // 只统计已有步骤，不额外截图、不额外等待；正式包不采集。
    var mark = watch.elapsedMicroseconds;
    void stage(String name) {
      _stallEvent('fold.stage.$name');
      final now = watch.elapsedMicroseconds;
      readerPerf(
        '${widget.traceLabel}.${widget.effect.name}.$name',
        now - mark,
        {'totalUs': now, 'token': token},
      );
      traceTurn(
        'fold stage=$name pointer=${_responseTrace.active} mode=${widget.traceLabel} token=$token '
        'stageUs=${now - mark} totalUs=$now',
      );
      if (const bool.fromEnvironment('GT_PROFILE_CAPTURE')) {
        debugPrint(
          'TURN_STAGE ${widget.traceLabel} $name ${now - mark}us at=${now}us',
        );
      }
      mark = now;
    }

    _foldPending = ReaderTurnStateDiagnostics.step(
      'fold.prepare',
      () async {
        final neighbour =
            _neighbour ??
            await _tracePageStep<Widget?>(
              'fold.resolve-neighbour',
              () async => await widget.resolvePage?.call(direction),
            );
        stage('resolve');
        if (!mounted || token != _foldToken) {
          traceTurn(
            'fold discarded stage=resolve token=$token $_traceInput mounted=$mounted',
          );
          return;
        }
        _neighbour = neighbour;
        if (neighbour == null) {
          traceTurn('fold no-neighbour $_traceInput');
          return;
        }
        final frames = await _tracePageStep<FoldFrames?>(
          'fold.prepare-images',
          () async => await widget.prepareFold?.call(direction),
        );
        stage('prepare');
        if (!mounted || token != _foldToken) {
          traceTurn(
            'fold discarded stage=prepare token=$token $_traceInput mounted=$mounted',
          );
          frames?.dispose();
          return;
        }
        if (widget.effect == PageTurnEffect.curl ||
            widget.effect == PageTurnEffect.cover) {
          frames?.preparePainting(
            context.size!,
            MediaQuery.devicePixelRatioOf(context),
            backward: direction == PageTurnDirection.backward,
            // 覆盖只平移整页图，不使用卷曲网格的裁剪图。
            curl: widget.effect == PageTurnEffect.curl,
          );
        }
        stage('paint');
        setState(() => _fold = frames);
        if (const bool.fromEnvironment('GT_PROFILE_CAPTURE')) {
          debugPrint(
            'TURN_READY ${widget.traceLabel} ${watch.elapsedMicroseconds}us',
          );
        }
      },
      observeStalls: _observeStalls,
      owner: this,
    );
    // 拖动起手就开始准备，Future 可能在松手等待它之前失败。
    // 先接住错误，松手仍从原 Future 取得结果并走统一的收尾流程。
    unawaited(
      _foldPending!.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    );
  }

  @override
  void didUpdateWidget(PageTurnArea oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.turnId != widget.turnId) _stallPageRevision++;
    _stallEvent('widget.update', {
      'pageChanged': oldWidget.turnId != widget.turnId,
      'revisionChanged': oldWidget.inputRevision != widget.inputRevision,
      'effectChanged': oldWidget.effect != widget.effect,
    });
    // 真的翻过去了：清掉冻结的相邻页与位移，回到稳定态
    if (oldWidget.inputRevision != widget.inputRevision ||
        oldWidget.effect != widget.effect ||
        (oldWidget.turnId != widget.turnId &&
            !_committing &&
            !_finishingInput)) {
      traceTurn(
        'input invalidated $_traceInput oldTurn=${oldWidget.turnId} '
        'revisionChanged=${oldWidget.inputRevision != widget.inputRevision} '
        'effectChanged=${oldWidget.effect != widget.effect}',
      );
      _ignorePointer = true;
      _dragFrames.stop();
      _clearFold();
    }
    if (oldWidget.turnId != widget.turnId ||
        oldWidget.effect != widget.effect ||
        oldWidget.inputRevision != widget.inputRevision) {
      traceTurn(
        'reset $_traceInput oldTurn=${oldWidget.turnId} commit=$_committing',
      );
      final landing = _committing ? _fold?.preparedTarget?.clone() : null;
      _resetTurn(landing: landing);
      _stallEvent('widget.reset');
    }
  }

  @override
  void dispose() {
    _blockedInputCheck?.cancel();
    ReaderTurnStateDiagnostics.detach(this);
    _dragLifecycle.dispose();
    _dragFrames.dispose();
    if (turnTraceEnabled ||
        const bool.fromEnvironment('GT_PROFILE_CAPTURE') ||
        const bool.fromEnvironment('GT_TRACE_FRAMES')) {
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
    return RepaintBoundary(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth.isFinite
              ? constraints.maxWidth
              : MediaQuery.sizeOf(context).width;
          return _buildInput(width);
        },
      ),
    );
  }

  Widget _buildStack(double width) {
    if (_offset.abs() > 0.1 &&
        (_fold != null || (widget.prepareFold == null && _neighbour != null))) {
      _responseTrace.changedFrame(widget.traceLabel);
    }
    if (widget.effect == PageTurnEffect.none) return widget.currentPage;
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
      final frames = _fold;
      return Stack(
        fit: StackFit.expand,
        children: [
          current,
          // 连续变化的卷页无需让引擎尝试缓存每一帧不同的绘制结果。
          if (frames != null)
            CustomPaint(
              willChange: true,
              painter: widget.effect == PageTurnEffect.cover
                  ? CoverFramesPainter(
                      frames,
                      _offset,
                      _direction == PageTurnDirection.backward,
                    )
                  : FoldFramesPainter(
                      frames,
                      _foldProgress,
                      _direction == PageTurnDirection.backward,
                      _fromTop,
                      touchPosition: _touchPosition,
                      edgeCurl: _edgeCurl,
                      edgeOriginY: _edgeOriginY,
                      settledTouch: _settledTouch,
                    ),
            ),
        ],
      );
    }
    final neighbour = _neighbour;
    if (neighbour == null && widget.effect != PageTurnEffect.slide) {
      return current;
    }

    final forward = _direction == PageTurnDirection.forward;
    if (widget.effect == PageTurnEffect.cover) {
      // 未使用图片缓存的调用方也遵循同一覆盖顺序，底页始终不动。
      return Stack(
        fit: StackFit.expand,
        children: [
          forward ? neighbour! : current,
          Positioned(
            left: forward ? _offset : _offset - width,
            top: 0,
            bottom: 0,
            width: width,
            child: forward ? current : neighbour!,
          ),
        ],
      );
    }
    // 和卷页一样，图片未准备好时保留整张旧页，不能先推开正文露出空白。
    final showNeighbour =
        neighbour != null && (widget.prepareFold == null || _fold != null);
    return Stack(
      children: [
        if (showNeighbour)
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
                  child: neighbour,
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
            child: current,
          ),
        ),
      ],
    );
  }

  Size get _foldSize => widget.spread
      ? Size(context.size!.width / 2, context.size!.height)
      : context.size!;

  bool get _followsSpreadCorner =>
      widget.spread && widget.effect == PageTurnEffect.curl && !_edgeCurl;

  Future<void> _animateTo(
    double target, {
    bool cornerTap = false,
    bool tap = false,
  }) {
    _stallEvent('animation.begin');
    final turnLog = _turnLog;
    turnLog?.event('animation.begin', [_offset, target, tap, cornerTap]);
    final watch = readerPerformanceEnabled ? (Stopwatch()..start()) : null;
    final from = _offset;
    final progressFrom = _foldProgress;
    final spread = _followsSpreadCorner ? _fold?.spread : null;
    final size = spread?.leafSize ?? _foldSize;
    final fromLeft = !widget.spread && _direction == PageTurnDirection.backward;
    final corner = Offset(
      size.width,
      _edgeCurl ? _edgeOriginY! : (_fromTop ? 0 : size.height),
    );
    // 从上一帧画出的纸角或纸边开始收尾。
    final touch = _touchPosition;
    final touchFrom = touch == null
        ? corner
        : _followsSpreadCorner || _settledTouch
        ? spread?.boundCornerTouch(touch) ?? touch
        : PageFold.dragTouch(
            size,
            corner,
            touch,
            backward: fromLeft,
            edgeCurl: _edgeCurl,
          );
    final unfolded = fromLeft ? target != 0 : target == 0;
    final touchTo = Offset(unfolded ? size.width : -size.width, corner.dy);
    _settledTouch = true;
    final curve = CurvedAnimation(
      parent: _controller,
      curve: cornerTap ? Curves.easeInOutCubic : Curves.easeOutCubic,
    );
    final animation = Tween<double>(begin: from, end: target).animate(curve);
    void listener() {
      if (!mounted) return;
      _offset = animation.value;
      _touchPosition = cornerTap
          ? PageFold.tapCornerTouch(
              size,
              curve.value,
              backward: fromLeft,
              fromTop: _fromTop,
            )
          : PageFold.settleTouch(
              touchFrom,
              touchTo,
              curve.value,
              unfolded: unfolded,
            );
      _foldProgress =
          progressFrom + ((target == 0 ? 0 : 1) - progressFrom) * curve.value;
      _motion.value++;
      turnLog?.event('animation.tick', [_controller.value, _offset]);
    }

    _controller
      ..stop()
      ..duration = readerTurnDuration
      ..reset()
      ..addListener(listener);
    traceTurn(
      'animation begin $_traceInput from=$from target=$target '
      'durationMs=${_controller.duration?.inMilliseconds} tap=$tap',
    );
    return _controller
        .forward()
        .orCancel
        .catchError((Object error) {
          if (error is! TickerCanceled) throw error;
        })
        .whenComplete(() {
          _stallEvent('animation.end');
          turnLog?.event('animation.end', [_controller.value]);
          if (watch != null) {
            readerPerf(
              '${widget.traceLabel}.${widget.effect.name}.animation',
              watch.elapsedMicroseconds,
              {'cancelled': _controller.value < 1},
            );
          }
          traceTurn('animation end $_traceInput value=${_controller.value}');
          _controller.removeListener(listener);
          curve.dispose();
        });
  }
}
