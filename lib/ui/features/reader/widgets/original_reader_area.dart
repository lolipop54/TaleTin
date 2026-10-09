/// 阅读页里的原书排版正文区（W8）：把 WebView 壳接进阅读会话。
///
/// 边界（计划第 2 节的分工原则）——章序、位置、进度都在 Dart，这个组件只做四件事：
/// 1. 把「当前章 + 落点比例」下发给宿主页（换章只由 Dart 决定）；
/// 2. 把宿主页上报的位置交回会话（[ReaderSessionNotifier.reportOriginalPosition]），
///    换算成 `Locator` 落库；
/// 3. 同时把排版参数交给会话：原书模式下排版结果不用于绘制，但切回简化模式时
///    立刻要有版可画，否则用户会看到一次「先空白再排版」；
/// 4. 手势期间的点击分区由 [OriginalBody] 内部的透明层处理，中间点击交回阅读页。
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart'
    show GestureBinding, PointerCancelEvent, PointerEvent, PointerUpEvent, kTouchSlop;
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../core/widgets/book_loading.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../domain/models/reading_settings.dart';
import '../../../../domain/models/automatic_scan.dart';
import '../../../../domain/models/tts_state.dart';
import '../../../../domain/services/listening_service.dart';
import '../../../../app/di/app_providers.dart';
import '../view_models/listening_view_state.dart';
import '../../../../domain/models/annotation.dart';
import '../../../../domain/models/book_document.dart';
import '../../../../domain/models/locator.dart';
import '../../../../engine/layout/layout_options.dart';
import '../../../../engine/selection/original_selection_map.dart';
import '../../../../engine/selection/selection_range.dart';
import '../../../core/theme/gt_tokens.dart';
import '../../../core/theme/reading_theme.dart';
import '../view_models/original_layout_controller.dart';
import '../view_models/reader_session_view_model.dart';
import '../view_models/reader_highlights.dart';
import '../view_models/reader_view_model.dart';
import 'original_body.dart';
import 'original_preload_gate.dart';
import 'reader_display_transition.dart';
import 'page_information.dart';
import 'original_curl_area.dart';
import 'original_host_controller.dart';
import 'reader_drag_detector.dart';
import 'reader_turn_timing.dart';
import 'turn_trace.dart';
import 'page_canvas.dart' show kSelectionHighlight;
import 'selection_actions.dart';
import 'thought_popover.dart';
import 'selection_handles.dart'
    show
        fingerPushedOut,
        kEdgeTurnDelay,
        kHandleCenterOffset,
        kHandleRadius,
        kHandleTouchSize,
        pageEdgeHintFor,
        pageTurnDirectionFor;
import 'reader_information.dart';
import 'reader_bookmark.dart';
import 'reader_image_viewer.dart';
import 'reader_image_gallery.dart';
import 'scan_frames.dart';
import '../view_models/automatic_reading.dart';
import 'automatic_scan_area.dart';

part 'original_neighbor_slots.dart';
part 'original_turn_coordinator.dart';
part 'original_landing_coordinator.dart';
part 'original_speech_follow.dart';
part 'original_selection.dart';
part 'original_selection_drag.dart';
part 'original_highlights.dart';
part 'original_scan_preparation.dart';

/// 原书排版正文区。[controller] 由外层（阅读页）从
/// [originalLayoutProvider] 取好后传进来，保证这一层只在内容就绪时才存在。
class OriginalReaderArea extends ConsumerStatefulWidget {
  static Future<void> turn(GlobalKey key, bool forward) async {
    final state = key.currentState;
    if (state is! _OriginalReaderAreaState || !ready(key)) return;
    if (state._curlKey.currentState case final OriginalCurlAreaState curl) {
      await curl.turn(forward);
    } else if (await state._prepareManualTurn() && state.mounted &&
        state._handoverTarget == null && !state._slideAnim.isAnimating) {
      if (forward) { await state._host?.next(); }
      else { await state._host?.prev(); }
    }
  }
  @visibleForTesting
  static OriginalHostController? hostForTesting(GlobalKey key) =>
    (key.currentState as _OriginalReaderAreaState?)?._host;
  static Future<ScanPreparation> prepareScan(GlobalKey key, ValueChanged<ui.Image> cover) =>
      (key.currentState as _OriginalReaderAreaState)._scanKey.currentState!.widget.prepare(cover);
  static bool ready(GlobalKey key) {
    final state = key.currentState as _OriginalReaderAreaState?;
    return state != null && state._everReady && !state._landing &&
        state._host?.pageCount != null;
  }
  static Future<NativeReadingFrame?> capture(GlobalKey key) async {
    final state = key.currentState as _OriginalReaderAreaState?;
    final host = state?._host;
    if (state == null || host == null || !state._everReady || state._landing) return null;
    // 暂停中的扫描已由 Flutter 画出整页，不能用底下的单页网页盖掉扫描进度。
    if (state._scanKey.currentState?.frames != null) return null;
    await state._curlKey.currentState?.settleForSpeech(invalidatePages: false);
    final image = await (state._curlKey.currentState?.captureVisiblePage() ?? host.capture());
    return (image: image, bounds: state._webViewOrigin &
      Size(state._submittedPageWidth,
        state._stableHeight ?? image.height.toDouble()));
  }
  const OriginalReaderArea({
    super.key,
    required this.bookId,
    required this.session,
    required this.controller,
    required this.settings,
    required this.theme,
    required this.onCenterTap,
  });

  final String bookId;
  final ReaderSession session;
  final OriginalLayoutController controller;
  final ReadingSettings settings;
  final ReadingTheme theme;

  /// 点击正文中间区域（交给阅读页切控制栏）
  final VoidCallback onCenterTap;

  @override
  ConsumerState<OriginalReaderArea> createState() => _OriginalReaderAreaState();
}

class _OriginalReaderAreaState extends ConsumerState<OriginalReaderArea>
    with SingleTickerProviderStateMixin {
  final _speech = _SpeechFollowState();
  final _scanKey = GlobalKey<AutomaticScanAreaState>();

  /// 原书选区（S4）：临时高亮的矩形与所属章页
  final _selection = _OriginalSelectionState();

  /// 宿主页（WebView）在阅读页里的原点：选区矩形按它平移到页面坐标
  Offset _webViewOrigin = Offset.zero;

  /// 键盘没弹出时的正文区高度：键盘期间固定用它，避免重排导致跳页
  double? _stableHeight;

  /// 持久高亮的下发签名、待发批与版本（见 original_highlights.dart）
  int _highlightVersion = 0;
  final _chapterHighlightVersions = <OriginalHostController, int>{};
  final _preload = OriginalPreloadGate();

  /// 拖手柄期间的最新落点（手柄位置与手指位置）：一次算完再取最新的一个
  Offset? _pendingDragHandle;
  Offset? _pendingDragFinger;
  bool _pendingDragEnd = false;
  Future<void>? _selectionDragFlight;

  void _updateState(VoidCallback change) => setState(change);

  /// 全局指针事件：只要有手指抬起/取消，就当作这次手柄拖动结束。
  ///
  /// 原书正文是平台视图（WebView），手指抬起的事件可能被它拿走，手柄的
  /// onPanEnd/onPanCancel 就收不到——拖动态一直挂着，页沿计时一页页续下去。
  void _onGlobalPointer(PointerEvent event) {
    if (event is! PointerUpEvent && event is! PointerCancelEvent) return;
    if (!_selection.dragging && _selection.edgeTimer == null) return;
    _finishSelectionDrag();
  }

  /// 全局选区已经被别处收起（笔记面板里删除、返回键、点空白）时，本页的矩形、
  /// 页沿判定与提示跟着作废。
  ///
  /// 必须在 build 里同步清：宿主页画的持久高亮已经撤掉了，Flutter 这一层的临时
  /// 底色若留着，用户看到的就是「点了删除，高亮还在，翻页才消失」（真机反馈）。
  /// 这里只清内存状态、不动全局选区，也不调 setState（本来就在重建）。
  void _dropSelectionIfCleared(SelectionRange? selection, bool fromMark) {
    if (selection != null) {
      // 已保存高亮只清临时底色；刚量好的矩形仍用于摆放操作菜单。
      if (fromMark && _selection.hasOverlay) {
        unawaited(_hosts[_selection.chapter]?.clearSelection());
        _selection.hasOverlay = false;
      }
      return;
    }
    if (!_selection.hasOverlay && !_selection.active) return;
    unawaited(_hosts[_selection.chapter]?.clearSelection());
    _selection.hasOverlay = false;
    _selection.geometry = null;
    _selection.continuationAnchor = null;
    _selection.previousContinuationAnchor = null;
    _selection.version++;
    _cancelSelectionEdge();
    _selection.dragging = false;
    _selection.edgeHintShown = false;
    _selection.rects = const [];
  }

  /// 已经下发过的排版参数签名（与简化模式同一套键）
  String? _submitted;

  /// 已经分栏完成的章；与当前章不一致时说明新章还在排
  int? _paginatedChapter;

  /// 宿主页文档已就绪（框架脚本已执行）的章号：高亮下发看它
  int? _documentReadyChapter;

  /// 整块区域第一次可读之前显示加载态，避免先闪一个空框
  bool _everReady = false;
  // 跳转期间文档可以布局，但不能把初始页/预载页提前展示或保存。
  bool _landing = true;
  int _navigation = 0;
  int _curlKeyNavigation = -1;
  GlobalKey<OriginalCurlAreaState> _curlKey = GlobalKey();
  ui.Image? _jumpCover;
  Future<void>? _jumpCoverReady;
  int _heldJumps = 0;

  ({int chapter, int page, Completer<bool> ready})? _curlHandover;

  int? _landingFlight;
  int? _landedChapter;
  HostRelocate? _landingPosition;

  /// 换章进行中：期间的边界事件一律忽略，避免一次连点跳过好几章
  bool _switching = false;
  Timer? _switchGuard;

  /// 已经处理过的章内定位请求序号（进度滑块、书签回到原文、同章目录定位）
  int _lastJumpToken = 0;

  /// 本次拖动的累计位移（松手时交给宿主页判定）
  double _dragOffset = 0;
  double _dragDirection = 0, _dragTailTravel = 0, _dragReleaseDirection = 0;

  /// 本次拖动有没有把宿主页平移过（越界后要归零，见 [_resetHostShift]）
  bool _hostDragged = false;

  /// 每个槽（按章序号）各自的命令入口。
  /// 三章共用一个 WebView；命令按章节加载编号进入对应 iframe。
  final _hosts = <int, OriginalHostController>{};
  final _pageReady = <int, Completer<bool>>{};

  /// 当前页的命令入口；还没就绪时为 null（命令会被忽略）
  OriginalHostController? get _host => _hosts[widget.session.chapterIndex];

  /// 最近一次布局算出来的一页宽度（跨章滑动与松手判定的基准）
  double _submittedPageWidth = 0;

  /// 宿主页报回来的真实边界：'end' 章末、'start' 章首、'' 都不是
  String _edge = '';
  int _edgeRequestId = 0;

  /// 当前章已上报的页序与页数：用于边界判断与错开远端章节的预载时机
  int _page = 0;
  int _pageCount = 0;

  /// 上一个章槽（屏幕左侧）：章首往回拖时要看到的那一章
  final _prev = _NeighborSlot('上一章');

  /// 下一个章槽（屏幕右侧）：章末往前拖时要看到的那一章
  final _next = _NeighborSlot('下一章');

  /// 顺序跨章后暂缓挂载的远端章节。
  ///
  /// 新章首页正在滑入时加载远端 iframe，会让字体和图片解码
  /// 抢占首帧。先保留刚离开的章节，等这一轮换章动画走完再补远端槽
  /// （见 [_resumeBackground]）。
  int? _deferredNeighborOrdinal;

  /// 换章滑入还没开始（目标章还在分栏）：画面先停在刚离开的那一章，等目标章
  /// 排好、落点也定了再滑进来。滑入一张还在分栏的空白页就是用户看到的「闪一下」。
  bool _pendingEntrySlide = false;
  Timer? _entrySlideGuard;

  /// 正在滑出屏幕的那一章所在的槽：它的落位留到滑入动画结束后再做，
  /// 免得用户在它滑出去的过程中看到它跳页。
  _NeighborSlot? _settleAfterSlide;

  /// 本次拖动已经报过「相邻章还没就绪」，避免同一次拖动刷屏
  bool _notReadyLogged = false;

  /// 上一次渲染时的当前章序号（用来发现「换章了」并做交接）
  int? _lastCurrent;

  /// 跨章滑动位移：章内拖动由宿主页平移，越界的那部分滑动整个画面（含相邻章）
  final _slidePosition = ValueNotifier<double>(0);
  double get _slide => _slidePosition.value;
  set _slide(double value) => _slidePosition.value = value;

  /// 滑动的补间（松手提交/回弹、相邻章交接都用它，曲线与翻页动画同档位）
  late final AnimationController _slideAnim = AnimationController(
    vsync: this,
    duration: readerTurnDuration,
  );
  Animation<double>? _slideTween;
  VoidCallback? _slideDone;
  bool _plainInputBusy = false, _plainIgnorePointer = false;
  bool get _plainBusy => _plainInputBusy || _slideAnim.isAnimating ||
      _handoverTarget != null || _switching || _landing;

  /// 跨章滑动尚未交接完时忽略后续操作，不重启动画或累计补翻次数。
  int? _handoverTarget;
  int _handoverDirection = 0;
  int? _dragHandoverTarget;
  bool _waitingNeighbor = false;
  Timer? _waitingNeighborGuard;

  @override
  void initState() {
    super.initState();
    _initSpeech();
    _preload.addListener(_resumeBackground);
    // 兜底：手指抬起的事件可能被平台视图（WebView）拿走，手柄的 onPanEnd/
    // onPanCancel 收不到，拖动态一直挂着——页沿计时一页页续下去，页面翻个不停、
    // 手柄却落在别的页（真机反馈的「翻页后看不到也拖不动手柄」）
    GestureBinding.instance.pointerRouter.addGlobalRoute(_onGlobalPointer);
    widget.controller.holdPageDuringJump = _holdPageDuringJump;
    widget.controller.bookmarkAnchor = _bookmarkAnchor;
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

  @override
  void dispose() {
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_onGlobalPointer);
    _speech.lifecycle.dispose();
    _speech.service.setPageBoundaries(this, const []);
    widget.controller.holdPageDuringJump = null;
    widget.controller.bookmarkAnchor = null;
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
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(bookmarksProvider(widget.bookId), (previous, next) {
      if (next.hasValue && previous?.value != next.value) {
        unawaited(_refreshBookmarks());
      }
    });
    ref.watch(listeningViewStateProvider);
    _scheduleSpeech();
    final settings = widget.settings;
    final controlsVisible = ref.watch(
      readerProvider.select((s) => s.controlsVisible),
    );
    // 选区是两种排版共用的全局状态（返回键、收起顺序都按它判断）
    final selection = ref.watch(readerProvider.select((s) => s.selection));
    // 点已有高亮选出来的选区：只摆菜单，不画手柄与临时底色（用户口径）
    final fromMark = ref.watch(
      readerProvider.select((s) => s.selectionFromMark),
    );
    _dropSelectionIfCleared(selection, fromMark);
    // 持久高亮：标注有变化就重发一次（S6），与听书跟随同一套帧后调度
    final annotations =
        ref.watch(readerHighlightsProvider(widget.bookId));

    return LayoutBuilder(
      builder: (context, constraints) {
        // 与简化模式同一套可用区域算法：最大宽度 720、上下各留 verticalPadding。
        // 区别在左右边距的归属：原书模式的页边距交给宿主页做在列间距里，
        // WebView 自己占满整页宽——这样翻页/拖动时页面连同左右边距一起滑，
        // 与简化模式是同一手感（用户 W15 提的）。
        final pageWidth = math.min(
          constraints.maxWidth,
          GtSize.readingMaxWidth,
        );
        _submittedPageWidth = pageWidth;
        final margin = settings.horizontalPadding;
        final info = readerInformation(
          context,
          ref,
          widget.session,
          settings,
          widget.theme,
          widget.session.chapterIndex,
          widget.session.chapterProgress,
          bookmarked: _host?.bookmarkPages.containsValue(_page) ?? false,
        );
        // 键盘弹出时系统栏与窗口一起变，正文区高度会跟着变（实测 721 → 764）。
        // 高度一变宿主页就重新分栏、按锚点回位，用户看到的是「页面跳了几页」。
        // 这里记下没有键盘时的高度，键盘期间固定用它（与简化模式同一做法）。
        final keyboard = MediaQuery.viewInsetsOf(context).bottom;
        if (keyboard == 0) _stableHeight = constraints.maxHeight;
        final layoutHeight = _stableHeight ?? constraints.maxHeight;
        final contentSize = Size(pageWidth, layoutHeight);

        _submitIfChanged(
          Size(
            math.max(0, pageWidth - margin * 2),
            math.max(
              0,
              contentSize.height -
                  info.top -
                  info.bottom -
                  ReadingLimits.verticalPadding * 2,
            ),
          ),
        );
        _consumeJumpRequest(widget.session);
        _syncHandover(pageWidth);
        if (_curlKeyNavigation != _navigation) {
          _curlKeyNavigation = _navigation;
          _curlKey = GlobalKey();
        }
        final current = widget.session.chapterIndex;
        // 当前章首次分栏的落点（只看不取：分栏完成后 _finishChapterReadable 才取）
        final landingFraction = ref
            .read(readerSessionProvider(widget.bookId).notifier)
            .peekOriginalLandingFraction(current);
        // 三个槽：上一章 | 当前章 | 下一章。左右两侧各差一页宽（屏幕外，只留
        // _platformViewWarmupOverlap 那一丁点在线内保住绘制表面），拖动时跟着一起滑。
        // key 用章序号，换章时同一个 WebView 只是换位置复用
        final left = (constraints.maxWidth - pageWidth) / 2;
        // 纵向原点用**固定高度**算：键盘弹出时安全区底部会让可用高度变大，
        // 若按当前高度居中，整页 WebView 会先下移一段、关掉再回落；而 Flutter
        // 这一层的选区矩形是按原点算好的，不会跟着动，看上去就是高亮区域跳了一下
        final top = (layoutHeight - contentSize.height) / 2;
        _webViewOrigin = Offset(left, top);

        return AutomaticScanArea(key: _scanKey, bookId: widget.bookId,
          page: (bookId: widget.bookId, contentVersion: widget.session.book.contentVersion,
            layout: (settings.fontSize, settings.fontFamily, settings.bold, settings.indent,
              settings.lineHeight, settings.paragraphGapEm,
              settings.horizontalPadding, widget.theme, contentSize, info.top, info.bottom,
              _highlightSignature(annotations, includeChapter: false)),
            page: (current, _page, _navigation)),
          ready: () => mounted && _everReady && !_landing && _host?.pageCount != null,
          prepare: (cover) => _prepareScan(cover, info, contentSize),
          frameBounds: _webViewOrigin & contentSize,
          bounds: _webViewOrigin & contentSize,
          paper: widget.theme.background, line: widget.theme.secondary,
          child: Listener(
          onPointerDown: (event) {
            _plainIgnorePointer = _plainBusy;
            if (_plainIgnorePointer) readerPerf('original.${settings.pageTurnEffect.name}.ignored', 0);
            _preload.hold(event.pointer);
          },
          onPointerUp: (event) => _preload.release(event.pointer),
          onPointerCancel: (event) => _preload.release(event.pointer),
          child: Stack(
          children: [
            // 底色先铺满：原书文档在分栏完成前是隐藏的，这里保证看到的是主题色
            // 而不是 WebView 的默认白底（夜间模式下尤其明显）
            Positioned.fill(child: ColoredBox(color: widget.theme.background)),
            // 原生视图固定不动，跨章平移由内部三个 iframe 接续。
            Positioned(
              top: top, left: left, width: pageWidth, height: contentSize.height,
              child: OriginalBody(
                session: widget.controller.source, current: current, slide: _slidePosition,
                preload: _preload,
                chapters: [
                  _chapter(ordinal: current, isNeighbor: false,
                    initialFraction: landingFraction, margin: margin, settings: settings),
                  if (_prev.ordinal != null)
                    _chapter(ordinal: _prev.ordinal!, isNeighbor: true,
                      initialFraction: 1, margin: margin, settings: settings),
                  if (_next.ordinal != null)
                    _chapter(ordinal: _next.ordinal!, isNeighbor: true,
                      initialFraction: 0, margin: margin, settings: settings),
                ],
              ),
            ),
            // 透明手势层：点击分区与水平拖动都归 Flutter（与简化模式同一套判定），
            // 再由命令驱动宿主页。手势放在这一层而不是 WebView 里面，是为了让
            // 章末/章首的拖动也能参与（那种滑动要动 Flutter 这一侧的画面）。
            Positioned.fill(
              child:
                  widget.settings.pageTurnEffect == PageTurnEffect.curl ||
                      widget.settings.pageTurnEffect == PageTurnEffect.cover
                  ? OriginalCurlArea(
                      key: _curlKey,
                      beforeTurn: _prepareManualTurn,
                      preload: _preload,
                      // 先看有没有点在已有高亮/笔记上，再看图片（S6）
                      onImageTap: _openMarkOrImage,
                      viewportOrigin: _webViewOrigin,
                      effect: widget.settings.pageTurnEffect,
                      prefetchEnabled:
                          !ref.read(automaticReadingProvider(widget.bookId).notifier).canResume &&
                          !ref.watch(automaticReadingProvider(widget.bookId)).running &&
                          !ref.watch(automaticReadingProvider(widget.bookId)).preparing &&
                          !controlsVisible &&
                          ref.watch(readerProvider.select((s) => s.panel)) == ReaderPanel.none &&
                          selection == null &&
                          _jumpCover == null &&
                          !(_speechSnapshot.hasSession &&
                              _speechSnapshot.followReading) &&
                          _speech.visible,
                      host: _host,
                      paper: widget.theme.background,
                      information: _everReady && !_landing ? info : null,
                      // 高亮/笔记一变，翻页截图里的旧底色就不对了：签名进版本串，
                      // 让它连同排版参数一起作废缓存（与主题、跳转同一口径）
                      captureRevision: (
                        settings,
                        widget.theme,
                        contentSize,
                        widget.session.originalJump,
                        // 每章高亮已单独准备，换角色不改变正文像素。
                        _highlightSignature(annotations, includeChapter: false),
                        (selection, fromMark),
                        info.searchMenu?.svg,
                      ),
                      captureVersions: {
                        for (final entry in _hosts.entries)
                          entry.value: _captureVersions[entry.key] ?? 0,
                      },
                      resolve: _resolveCurlTarget,
                      commit: _commitCurl,
                      prefetchResolve: (backward) =>
                          _resolveCurlTarget(backward, silent: true),
                      positionRevision: (
                        widget.session.chapterIndex,
                        _page,
                      ),
                      onCenterTap: widget.onCenterTap,
                      onError: _notice,
                    )
                  : ReaderDragDetector(
                      onTapUp: (details) => _runPlainInput(() => _onTapUp(details, pageWidth)),
                      onHorizontalDragStart: (_) => _onDragStart(pageWidth),
                      onHorizontalDragUpdate: (details) =>
                          _onDragUpdate(details),
                      onHorizontalDragEnd: (details) => _runPlainInput(() => _onDragEnd(details)),
                      onHorizontalDragCancel: _onDragCancel,
                    ),
            ),
            // 临时底色由宿主页随正文绘制，仿真/覆盖截图也包含各页的选区。
            // 长按选文：只登记长按，点按与拖动继续交给下面的翻页手势层
            // （translucent 不挡住命中测试，自己只参与长按这一个识别器）
            if (!_landing && _everReady)
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  // 有选区时点一下正文先收选区，与简化模式一致
                  onTap: selection == null ? null : _clearSelection,
                  onLongPressStart: (details) =>
                      unawaited(_beginSelection(details.localPosition)),
                  onLongPressEnd: (_) {},
                ),
              ),
            // 起止手柄：拖着改选区两端；拖到页沿停够时长翻页继续扩选（S5）。
            // 点已有高亮选出来的那段不画手柄：改范围只能删掉再重选（用户口径）
            if (selection != null && !fromMark && _everReady)
              Positioned.fill(
                // 页序改变会重算手柄位置，固定此层身份，保留正在进行的拖动。
                key: const ValueKey('original-selection-handles-layer'),
                child: _OriginalSelectionHandles(
                  startAnchor: _selection.startAnchor,
                  endAnchor: _selection.endAnchor,
                  color: ref.context.gtColors.actionPrimary,
                  onDragStart: _beginSelectionDrag,
                  onDrag: (atEnd, handle, finger) =>
                      unawaited(_dragSelection(atEnd, handle, finger)),
                  onDragEnd: _finishSelectionDrag,
                ),
              ),
            // 选中文字后的操作菜单（S5）：与简化模式同一个组件、同一套规则，
            // 矩形已经是阅读页坐标，因此原点传零；翻页扩选期间矩形为空就先收起
            if (selection != null && !_landing)
              Positioned.fill(
                child: SelectionActions(
                  bookId: widget.bookId,
                  state: ref.read(readerProvider),
                  rects: _selection.rects,
                  origin: Offset.zero,
                  pageSize: Size(constraints.maxWidth, constraints.maxHeight),
                ),
              ),
            // 拖动跨章时，目标页已经完整滑入；落位确认期间不能再盖空白。
            if (_landing &&
                _curlHandover == null &&
                _jumpCover == null &&
                _handoverTarget != current)
              Positioned.fill(
                child: ColoredBox(color: widget.theme.background),
              ),
            if (_jumpCover == null && !_everReady)
              const Center(
                child: BookLoading(),
              ),
            if (_jumpCover != null)
              Positioned.fill(
                child: AbsorbPointer(
                  child: RawImage(image: _jumpCover, fit: BoxFit.fill),
                ),
              ),
            if (_speech.resuming)
              Positioned.fill(
                child: ColoredBox(color: widget.theme.background),
              ),
          ],
        )));
      },
    );
  }

  /// 章节配置与回调；真正的文档由固定 iframe 保留。
  OriginalChapter _chapter({
    required int ordinal,
    required bool isNeighbor,
    required double? initialFraction,
    required double margin,
    required ReadingSettings settings,
  }) => OriginalChapter(
    session: widget.controller.source,
    ordinal: ordinal,
    fontSizePx: _fontSizePx(context, settings),
    lineHeight: settings.lineHeight,
    paragraphGapEm: settings.paragraphGapEm,
    columnMarginPx: margin,
    indent: settings.indent,
    fontFamily: settings.useOriginalFont
        ? ''
        : settings.fontFamily ?? 'sans-serif',
    bold: settings.bold,
    // 相邻章各自的落位：上一章落章末、下一章落章首，滑进来时正是要看到的那一页
    initialFraction: initialFraction,
    themeColors: _themeColors(),
    information:
        readerInformation(
            context,
            ref,
            widget.session,
            settings,
            widget.theme,
            ordinal,
            initialFraction ?? widget.session.chapterProgress,
            showReturnProgress: !isNeighbor,
          ).toHost(
            widget.session.bookProgressAt(ordinal, 0),
            widget.session.bookProgressAt(ordinal, 1),
          )
          ..['pageTurnEffect'] = settings.pageTurnEffect.name
          ..['paintInHost'] =
              settings.pageTurnEffect != PageTurnEffect.curl &&
              settings.pageTurnEffect != PageTurnEffect.cover,
    preparationRevision: (
      ref.watch(annotationsProvider(widget.bookId)).hasValue,
      _highlightSignature(ref.watch(readerHighlightsProvider(widget.bookId)), includeChapter: false),
    ),
    prepare: (host) => _prepareChapterHighlights(ordinal, host),
    onControllerReady: (host) => _hosts[ordinal] = host,
    onHostEvent: (raw) =>
        _onRawMessage(raw, isNeighbor: isNeighbor, ordinal: ordinal),
  );

  /// 仿真/覆盖排版下的点击：先判断是不是点在已有高亮/笔记上（S6），再看图片。
  ///
  /// 这两种翻页效果走 [OriginalCurlArea] 自己的点击通道，不经过 [_onTapUp]，
  /// 所以入口要在这里也接一次，两种翻页效果的手感才一致。
  Future<bool> _openMarkOrImage(Offset point) async {
    final auto = ref.read(automaticReadingProvider(widget.bookId).notifier);
    if (auto.consumePauseTap()) return true;
    final ratio = (point.dx - _webViewOrigin.dx) / _pageWidth;
    if (auto.canResume && ratio >= GtReadingTapZones.previousEdge && ratio <= GtReadingTapZones.nextEdge) {
      widget.onCenterTap(); return true;
    }
    await auto.discard();
    if (!mounted) return true;
    final host = _host;
    if (host == null || _landing) return true;
    final hit = await host.tapTarget(_toViewport(point));
    if (!mounted || host != _host) return true;
    if (await _openHighlightAt(point, hit: hit)) return true;
    if (await _openImage(point, hit: hit)) return true;
    return hit.link != null && hit.link!.isNotEmpty
        ? host.activateLink(_toViewport(point), knownLink: hit.link) : false;
  }

  /// 正文字号（像素）：用户字号 × 系统字号缩放。
  ///
  /// WebView 不感知 Flutter 的缩放，所以必须由 Dart 算好再传下去
  /// （与简化模式同一个来源，两模式口径差异见 W10 实测）。
  double _fontSizePx(BuildContext context, ReadingSettings settings) =>
      MediaQuery.textScalerOf(context).scale(settings.fontSize.toDouble());

  Map<String, String> _themeColors() => {
    'bg': hexOf(widget.theme.background),
    'text': hexOf(widget.theme.primary),
    'link': hexOf(readingLinkColor(widget.theme)),
  };

  /// 把可用区域对应的排版参数交给会话（不预取相邻章：原书模式用不上）。
  ///
  /// 宽度变化不用在这里处理：[OriginalBody] 自己盯着自己的宽度，变了会通知
  /// 宿主页重新分栏并保持位置。
  void _submitIfChanged(Size contentSize) {
    final options = LayoutOptions(
      settings: widget.settings,
      contentSize: contentSize,
      textScaler: MediaQuery.textScalerOf(context),
    );
    if (_submitted == options.layoutSignature) return;
    _submitted = options.layoutSignature;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(
        ref
            .read(readerSessionProvider(widget.bookId).notifier)
            // 原书模式的正文由 WebView 画：这里只记排版参数，不排简化版。
            // 排一整章按字数花时间（整本正文一个文件的书写，实测 2.2 秒），
            // 只有切回简化模式才用得上，那一步再排（setLayoutMode / goToLocator）
            .applyViewport(options, prefetch: false, paginate: false),
      );
    });
  }

  Future<bool>? _manualDrag;
  final _captureVersions = <int, int>{};
}
