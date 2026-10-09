/// 选区起止手柄（实现计划 S1b）。
///
/// 简化模式的选区靠两个手柄调整：起点手柄改选区开头，终点手柄改结尾。
/// 手柄画在行下方一小段距离，拖的时候手指不挡着要看的那行字。
///
/// **拖到左上角/右下角并停 0.8 秒翻页**：左上角翻上一页，右下角翻下一页。
/// 只靠近一条边不会翻页；手指离开角落或松手就取消计时。
///
/// 翻完页后拖动的那一端落在**新页靠近手指的那一侧**（往后翻落新页页首、
/// 往回翻落新页页末），也就是刚跨过的那条页边界：拖过来之后它就在新页上，
/// 看得见、抓得到，接着拖就能继续跨页高亮。整段选区至始至终只有一对手柄——
/// 另一端在别的页时本页不画，要调它就翻回它所在的那一页。
/// 手指还停在页沿就接着计时，一页页往外扩；手指拖回正文里就按落点定位。
///
/// 坐标口径：手柄在正文盒子坐标系里算位置（与 `PageCanvas` 的绘制坐标一致），
/// 放进页面区域时加上正文盒子的原点；拖动时按指针位移累加，
/// 不去反算页面坐标，避免手柄自身移动带来的偏移。
library;

import 'dart:async';

import 'package:flutter/gestures.dart'
    show GestureBinding, PointerCancelEvent, PointerEvent, PointerUpEvent;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/di/app_providers.dart';
import '../../../../domain/models/locator.dart';
import '../../../../engine/layout/chapter_layout.dart';
import '../../../core/theme/gt_tokens.dart';
import '../../../core/theme/reading_theme.dart';
import '../view_models/reader_session_view_model.dart';
import '../view_models/reader_view_model.dart';

/// 触摸目标（移动端最小尺寸）
const double kHandleTouchSize = 44;

/// 手柄在测试与调试里的定位键
const String kHandleStartKey = 'selection-handle-start';
const String kHandleEndKey = 'selection-handle-end';

/// 手柄圆点半径
const double kHandleRadius = 8;

/// 圆点中心到高亮底边的距离（竖线长度 + 半径）：
/// 太短不好抓、太长拖着一根杆，取一小段
const double kHandleCenterOffset = 22;

/// 停在页边多久才翻页：按用户要求 0.8 秒。
/// 太短手指路过页沿就会误翻，太长又显得拖沓
const Duration kEdgeTurnDelay = Duration(milliseconds: 800);

/// 翻页角落在正文盒内的边长；越过正文盒的同一角仍可继续扩选。
const double kEdgeTurnMargin = 32;

/// 手柄拖到页首/页尾多少逻辑像素内才算「拖到了页首/页尾」（约一行半）
const double kEdgeLineBand = 44;

/// 「拖到页首往外 / 拖到页尾往外」的翻页方向：-1 上一页、1 下一页、0 不翻。
///
/// 手柄靠近页首/页尾，且手指同时靠近对应的两条边才翻页。
/// 页尾中间、侧边中间与最后一段的普通文字位置都不会启动倒计时。
///
/// [handle] 是拖动落点（手柄位置），[finger] 是手指在正文盒里的位置——
/// 越没越过页沿看手指，落在页首还是页尾看手柄。
int pageTurnDirectionFor({
  required Offset handle,
  required Offset finger,
  required Size contentSize,
}) {
  final atHead = handle.dy <= kEdgeLineBand;
  final atTail = handle.dy >= contentSize.height - kEdgeLineBand;
  if (atTail && fingerPushedOut(finger, contentSize, 1)) return 1;
  if (atHead && fingerPushedOut(finger, contentSize, -1)) return -1;
  return 0;
}

/// 手柄落在页首/页末那一带时给用户的提示。
///
/// 手柄拖到页首/页末那一带、再往外推停一下就能翻页，这条提示把这个用法说出来。
const String kEdgeHeadHint = '长按页首翻页';
const String kEdgeTailHint = '长按页尾翻页';

/// 手柄落在页首/页末那一带时该提示哪一句；在页中间返回 null。
String? pageEdgeHintFor(Offset handle, Size contentSize) {
  if (handle.dx <= kEdgeTurnMargin && handle.dy <= kEdgeLineBand) {
    return kEdgeHeadHint;
  }
  if (handle.dx >= contentSize.width - kEdgeTurnMargin &&
      handle.dy >= contentSize.height - kEdgeLineBand) {
    return kEdgeTailHint;
  }
  return null;
}

/// 手指是不是还推在页面外（不看手柄）：翻完页接着计时用它。
///
/// 翻完页端点已经落到新页上，手柄位置不再代表「手指还在页沿」，
/// 这时只看手指有没有离开页面——还在就继续计时、一页页往外扩。
bool fingerPushedOut(Offset finger, Size contentSize, int direction) {
  final outLeft = finger.dx <= kEdgeTurnMargin;
  final outRight = finger.dx >= contentSize.width - kEdgeTurnMargin;
  final outTop = finger.dy <= kEdgeTurnMargin;
  final outBottom = finger.dy >= contentSize.height - kEdgeTurnMargin;
  return direction > 0 ? (outBottom && outRight) : (outTop && outLeft);
}

class SelectionHandles extends ConsumerStatefulWidget {
  const SelectionHandles({
    super.key,
    required this.bookId,
    required this.state,
    required this.layout,
    required this.pageIndex,
    required this.origin,
    required this.theme,
    this.paintIdleHandles = true,
    this.onDragChanged,
  });

  final String bookId;
  final ReaderState state;
  final ChapterLayout layout;
  final int pageIndex;

  /// 正文盒子（页内容盒）左上角在页面区域里的位置
  final Offset origin;
  final ReadingTheme theme;

  /// 静止手柄可以交给书页绘制，触摸层只画正在拖动的一端。
  final bool paintIdleHandles;
  final ValueChanged<bool?>? onDragChanged;

  @override
  ConsumerState<SelectionHandles> createState() => _SelectionHandlesState();
}

class _SelectionHandlesState extends ConsumerState<SelectionHandles> {
  /// 手指当前落在正文盒的哪个位置。
  ///
  /// 拖动期间选区一变，上层就会重建手柄；落点必须存在 State 里，
  /// 放在 build 的闭包里会被重建重置回起点，拖起来就不动了。
  Offset? _dragPoint;

  /// 正在拖的是哪一端
  bool _dragAtEnd = true;

  /// 拖动那一端所在行的高度：绘制位置 = 落点 + 半行高，
  /// 这样按下手柄时它停在原地，之后才跟着手指走
  double _dragHalfLine = 0;

  /// 停在页外的翻页倒计时（1 秒）；手指回到页内或松手就取消
  Timer? _edgeTimer;

  /// 手指最近一次在正文盒里的位置：换页后判断手指是否还停在页边用它
  Offset? _fingerPoint;

  /// 正在换页：一次只处理一个目标页，换页期间忽略后续移动
  bool _turning = false;

  /// 倒计时当前的方向（1 往后、-1 往回、0 没在计时）：手指回到正文里时用它判断
  int _edgeDirection = 0;

  /// 当前这条高亮是否已经提示过页首/页末那句：同一条高亮只提示一次
  bool _hintShown = false;

  /// 扩选刚落页且手指尚未继续移动时，手柄暂时贴住新页端点。
  bool _landedAtEdge = false;

  @override
  void initState() {
    super.initState();
    // 兜底：手指抬起的事件可能被别的层（原书那边是平台视图）拿走，手柄的
    // onPanEnd/onPanCancel 收不到，拖动状态就一直挂着——页沿计时一页页续下去，
    // 页面翻个不停、手柄却还在别的页（真机反馈的「看不到也拖不动」）。
    GestureBinding.instance.pointerRouter.addGlobalRoute(_onGlobalPointer);
  }

  @override
  void dispose() {
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_onGlobalPointer);
    _edgeTimer?.cancel();
    super.dispose();
  }

  /// 全局指针事件：只要有手指抬起/取消，就当作这次拖动结束
  void _onGlobalPointer(PointerEvent event) {
    if (event is! PointerUpEvent && event is! PointerCancelEvent) return;
    if (_dragPoint == null && _edgeTimer == null) return;
    _finishDrag();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final selection = state.selection;
    if (selection == null) {
      // 选区收起来了：下一条高亮可以再提示一次页首/页末
      _hintShown = false;
      return const SizedBox.shrink();
    }
    // 一对手柄：两端各自画在自己所在的那一页，别的页不补（所有页面加起来只这一对）
    return Stack(
      children: [
        ?_handle(context, selection.start, atEnd: false),
        ?_handle(context, selection.end, atEnd: true),
      ],
    );
  }

  /// 一端的手柄。
  ///
  /// 正被拖的那一端画在手指位置：换页期间它可能已经不在当前页上，
  /// 若按光标位置算就会消失，一下消失手势会被取消，拖动直接断掉。
  Widget? _handle(
    BuildContext context,
    Locator locator, {
    required bool atEnd,
  }) {
    final dragPoint = _dragPoint;
    final dragging = dragPoint != null && _dragAtEnd == atEnd;
    // 画的时候按当前这一页来（父级给的页号）：只在**这一端真的落在本页**时画，
    // 落在别的页就不画——所有页面加起来至始至终只有一对手柄。
    // 想够到另一头就拖着本页这一端往页沿停一下翻过去（翻完页端点会落到新页上）。
    final caret = ref
        .read(readerEngineProvider)
        .caretAt(widget.layout, widget.pageIndex, locator, atEnd: atEnd);
    if (!dragging && caret == null) return null;
    // 手柄画在这一行的下方：竖线顶着高亮底边，中间不留空。
    //
    // 拖动时画在手指位置（换页那一瞬间它可能已经不在新页上，按光标算会消失，
    // 手柄一消失手势就被取消）。**不要在这里夹位置**：夹取会让页尾的手柄
    // 在按下那一刻整体上移一截（落点被压进页面内），看起来就是手柄自己跳了。
    //
    // 例外：扩选刚落页、手指尚未再移动时，手柄暂时贴住新页端点。
    // 翻完页端点已经落到新页页首/页末，若还按落点画，就会先在新页上看到上一页
    // 那个残留位置、松手才跳过去（用户反馈的跳变）。
    final atEndPoint = dragging && _landedAtEdge && caret != null;
    final wanted = (dragging && !atEndPoint)
        ? dragPoint.dy + _dragHalfLine
        : caret!.bottom;
    final left = (dragging && !atEndPoint) ? dragPoint.dx : caret!.left;
    return Positioned(
      key: ValueKey(atEnd ? kHandleEndKey : kHandleStartKey),
      left: widget.origin.dx + left - kHandleTouchSize / 2,
      top: widget.origin.dy + wanted,
      width: kHandleTouchSize,
      height: kHandleTouchSize,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        // 手柄上按住不放不再起一次选句
        onLongPress: () {},
        onPanStart: (_) {
          final start = caret;
          if (start == null) return;
          widget.onDragChanged?.call(atEnd);
          _dragAtEnd = atEnd;
          _dragHalfLine = start.height / 2;
          _landedAtEdge = false;
          _dragPoint = Offset(start.left, start.top + _dragHalfLine);
          _updateEdgeHint(_dragPoint!, widget.layout.contentSize);
          setState(() {}); // 换到「跟着手指画」
        },
        onPanUpdate: (details) {
          final from = _dragPoint;
          if (from == null) return;
          final point = from + details.delta;
          // 落点是绘制位置的基准，改了要重建一次：否则落点挪到了正文外、
          // 选区不再变化时，父级不会重建，手柄就停在原地不跟手了
          setState(() {
            _dragPoint = point;
            _landedAtEdge = false; // 再移动就恢复跟手，包括交叉后的页外拖动。
          });
          if (_turning) return; // 目标页还没就绪，先忽略移动（一次只处理一页）
          final page = _currentPage();
          final contentSize = page.layout.contentSize;
          final finger = _fingerInContent(details.globalPosition) ?? point;
          _fingerPoint = finger;
          // 到页沿只做一件事：开始/继续翻页倒计时。
          // 不动选区——早先版本在这里把选区「铺到本页页沿」，手指只推出去一点，
          // 高亮就一下跳出去好几个字（用户真机反馈）。
          final direction = pageTurnDirectionFor(
            handle: point,
            finger: finger,
            contentSize: contentSize,
          );
          if (direction != 0) {
            _startEdgeTimer(direction);
          } else if (!fingerPushedOut(finger, contentSize, _edgeDirection)) {
            _cancelEdgeTurn(); // 手指真的回到正文里了：不翻了
          }
          _updateEdgeHint(point, contentSize);
          // 不管在不在页外都按落点定位：推出去的过程中高亮连续跟手
          final target = ref
              .read(readerEngineProvider)
              .locatorAtPoint(page.layout, page.pageIndex, point);
          if (target != null) _applySelection(target);
        },
        onPanEnd: (_) => _finishDrag(),
        onPanCancel: _finishDrag,
        child: CustomPaint(
          painter: widget.paintIdleHandles || dragging
              ? SelectionHandlePainter(
                  color: ref.context.gtColors.actionPrimary,
                  atEnd: atEnd,
                )
              : null,
        ),
      ),
    );
  }

  /// 会话里现在看的是哪一页：算拖动落点与翻页用它。
  ///
  /// 换页刚完成那一帧，widget 上还是旧页（父级要下一帧才重建），
  /// 用旧页会把刚扩好的选区又拉回去，所以这两处以会话里的排版与页号为准。
  ({ChapterLayout layout, int pageIndex}) _currentPage() {
    final session = ref.read(readerSessionProvider(widget.bookId)).value;
    final layout = session?.layout;
    if (session == null || layout == null || !session.isReady) {
      return (layout: widget.layout, pageIndex: widget.pageIndex);
    }
    return (layout: layout, pageIndex: session.pageIndex);
  }

  /// 手指在正文盒里的位置（页面坐标减掉正文盒原点）；拿不到盒子时返回 null。
  ///
  /// 页面（手柄铺满的那一层）左上角为原点，局部坐标减掉正文盒原点就是它在
  /// 正文盒坐标系里的位置——[pageTurnDirectionFor] 的「推到页面哪一侧」用它。
  Offset? _fingerInContent(Offset global) {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return null;
    return box.globalToLocal(global) - widget.origin;
  }

  /// 开始倒计时（已经在计时就不重开）：停在页沿够 0.8 秒就翻页。
  void _startEdgeTimer(int direction) {
    if (_edgeDirection != direction) _cancelEdgeTurn();
    _edgeDirection = direction;
    if (_edgeTimer != null) return; // 已经在计时
    _edgeTimer = Timer(kEdgeTurnDelay, () {
      _edgeTimer = null;
      unawaited(_turnPage(direction));
    });
  }

  /// 手指回到页内或松手：撤销翻页倒计时
  void _cancelEdgeTurn() {
    _edgeDirection = 0;
    _edgeTimer?.cancel();
    _edgeTimer = null;
  }

  /// 停在页外够 0.8 秒：翻到相邻页，并把拖动的那一端带到新页靠近手指的一侧。
  ///
  /// 换页期间忽略后续移动（一次只处理一个目标页）；换页完成后若手指仍停在
  /// 页外就重新计时——继续停着就一页一页往外扩。到书首/书尾停住，不空翻。
  Future<void> _turnPage(int direction) async {
    if (_turning) return;
    // 选区已经被收掉（例如另一只手点了一下正文）：不翻页
    if (widget.state.selection == null) return;
    _turning = true;
    try {
      final notifier = ref.read(readerSessionProvider(widget.bookId).notifier);
      final result = direction > 0
          ? await notifier.nextPage()
          : await notifier.previousPage();
      if (!mounted) return;
      // 到书首/书尾：停住。手指再动一动才会重新判断（不反复空翻）
      if (result != PageTurnResult.moved) return;
      final page = _currentPage();
      // 拖动的那一端落在**新页靠近手指的那一侧**，也就是刚跨过的那条页边界：
      // 往后翻落新页页首、往回翻落新页页末。
      final edge = ref
          .read(readerEngineProvider)
          .pageEdge(page.layout, page.pageIndex, atEnd: direction < 0);
      _landedAtEdge = true;
      if (edge != null) _applySelection(edge);
      // 手指还停在页沿：接着计时，再停 0.8 秒就再翻一页
      final finger = _fingerPoint;
      if (finger != null &&
          fingerPushedOut(finger, page.layout.contentSize, direction)) {
        _startEdgeTimer(direction);
      }
    } finally {
      _turning = false;
    }
  }

  /// 改选区当前在拖的那一端
  void _applySelection(Locator target) {
    final vm = ref.read(readerProvider.notifier);
    if (_dragAtEnd) {
      vm.setSelectionEnd(target);
    } else {
      vm.setSelectionStart(target);
    }
  }

  /// 结束拖动：撤销翻页倒计时与提示，落下拖动状态（手柄回到选区两端的位置）
  void _finishDrag() {
    if (_dragPoint != null) widget.onDragChanged?.call(null);
    _cancelEdgeTurn();
    _fingerPoint = null;
    _landedAtEdge = false;
    _updateEdgeHint(null, widget.layout.contentSize);
    if (_dragPoint == null) return;
    setState(() => _dragPoint = null);
  }

  /// 手柄落在页首/页末那一带时说一句「长按这里能翻页」。
  ///
  /// **同一条高亮只提示一次**（用户要求）：说过就不再弹，免得拖来拖去反复打扰；
  /// 选区收起来之后（下一条高亮）才会再提示。提示条自己 1.4 秒后消失。
  void _updateEdgeHint(Offset? handle, Size contentSize) {
    if (_hintShown || handle == null) return;
    final hint = pageEdgeHintFor(handle, contentSize);
    if (hint == null) return;
    _hintShown = true;
    ref.read(readerProvider.notifier).showNotice(hint);
  }
}

/// 选区期间盖在正文上的手势层。
///
/// 只吃掉**点按**（点一下先收起选区），拖动手势继续传给下面的翻页区，
/// 所以选区在的时候仍然可以拖动翻页——跨页选区要看另一头就靠它。
/// 手柄与菜单在这一层之上，不受影响。
class SelectionGestureShield extends StatelessWidget {
  const SelectionGestureShield({super.key, required this.onDismiss});

  /// 点正文空白处收起选区
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) => GestureDetector(
    // translucent：自己不挡命中测试，点按由这里处理、拖动交给正文
    behavior: HitTestBehavior.translucent,
    onTap: onDismiss,
    child: const SizedBox.expand(),
  );
}

/// 手柄：一条竖线连到圆点，起点手柄线在圆点左侧、终点手柄线在右侧
class SelectionHandlePainter extends CustomPainter {
  const SelectionHandlePainter({required this.color, required this.atEnd});

  final Color color;
  final bool atEnd;

  @override
  void paint(Canvas canvas, Size size) {
    final fill = Paint()..color = color;
    // 圆点固定在贴住高亮底边的一小段距离上：盒子做得大是为了好点中，
    // 视觉上只留圆点和很短的一段竖线
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
  bool shouldRepaint(SelectionHandlePainter old) =>
      old.color != color || old.atEnd != atEnd;
}
