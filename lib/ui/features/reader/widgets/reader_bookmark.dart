import 'package:taletin/core/diagnostics/app_errors.dart';

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/di/app_providers.dart';
import '../../../../core/diagnostics/bookmark_trace.dart';
import '../../../../domain/models/bookmark.dart';
import '../../../../domain/models/book.dart';
import '../view_models/reader_session_view_model.dart';
import '../view_models/reader_view_model.dart';
import '../view_models/pdf_viewport.dart';
import '../view_models/pdf_book_provider.dart';
import '../view_models/original_layout_controller.dart';
import '../../../core/theme/gt_tokens.dart';
import 'bookmark_ribbon.dart';
import 'book_paper.dart';
import '../view_models/reader_settings_view_model.dart';
import '../view_models/visible_spread.dart';
import 'reader_drag_detector.dart';
export 'bookmark_ribbon.dart' show bookmarkRibbonColor;

/// 原书由真实 DOM 分页结果提供当前页的书签，不用文字比例猜页码。
final originalPageBookmarksProvider = NotifierProvider.autoDispose
    .family<
      OriginalPageBookmarks,
      ({String chapter, Set<String> ids})?,
      String
    >(OriginalPageBookmarks.new);

class OriginalPageBookmarks
    extends Notifier<({String chapter, Set<String> ids})?> {
  OriginalPageBookmarks(this.bookId);
  final String bookId;
  @override
  ({String chapter, Set<String> ids})? build() => null;
  void update(String chapter, Set<String> ids) {
    final old = state;
    if (old?.chapter == chapter &&
        old!.ids.length == ids.length &&
        old.ids.containsAll(ids)) {
      return;
    }
    state = (chapter: chapter, ids: ids);
  }
}

final currentBookmarkProvider = Provider.autoDispose.family<Bookmark?, String>((
  ref,
  id,
) {
  final session = ref.watch(readerSessionProvider(id)).value;
  final anchor = session?.currentAnchor;
  if (session == null || anchor == null) return null;
  final marks = ref.watch(bookmarksProvider(id)).value ?? const <Bookmark>[];
  final original = ref.watch(originalPageBookmarksProvider(id));
  final spread =
      ref.watch(readerSettingsProvider(id)).value?.settings.spreadEnabled ==
          true
      ? ref.watch(visibleSpreadProvider(id))
      : const <SpreadPageRef>[];
  for (final mark in marks) {
    if (mark.locator.needsRelocation) continue;
    if (!session.isOriginal && spreadContains(spread, mark.locator)) {
      return mark;
    }
    if (session.book.format.usesOriginalWebView &&
        session.isOriginal &&
        !session.scrolling &&
        original?.chapter == anchor.chapterId) {
      if (original!.ids.contains(mark.id)) return mark;
      continue; // 原书页首可能跨段，已取得DOM页码后不再用近似页首匹配上一页。
    }
    if (session.book.format == BookFormat.pdf &&
        session.isOriginal &&
        !session.scrolling &&
        mark.locator.chapterId == anchor.chapterId) {
      return mark;
    }
    if (mark.isAt(anchor)) return mark;
    // 简化分页重排后页首会改变，书签所在页仍应显示条带并允许取消。
    if (!session.scrolling &&
        !session.isOriginal &&
        mark.locator.chapterId == session.chapter.id &&
        session.layout?.pageIndexOf(mark.locator) == session.pageIndex) {
      return mark;
    }
  }
  return null;
});

Future<void> toggleReaderBookmark(WidgetRef ref, String id) async {
  final session = ref.read(readerSessionProvider(id)).value;
  final anchor = session?.currentAnchor;
  if (session == null || anchor == null) return;
  final mark = ref.read(currentBookmarkProvider(id));
  final repository = ref.read(annotationRepositoryProvider);
  if (mark != null) {
    traceBookmark('remove', {
      'id': mark.id,
      'locator': bookmarkTraceLocator(mark.locator),
    });
    final spread =
        ref.read(readerSettingsProvider(id)).value?.settings.spreadEnabled ==
        true;
    final visible = ref.read(visibleSpreadProvider(id));
    final original = ref.read(originalPageBookmarksProvider(id));
    // 横屏前左右两页可能各有历史书签；共用条带取消时一并移除这组可见书签。
    final ids = <String>{
      mark.id,
      if (spread)
        for (final m
            in ref.read(bookmarksProvider(id)).value ?? const <Bookmark>[])
          if (session.isOriginal
              ? original?.ids.contains(m.id) == true
              : spreadContains(visible, m.locator))
            m.id,
    };
    for (final bookmarkId in ids) {
      await repository.removeBookmark(bookmarkId);
    }
  } else {
    final exact =
        session.book.format.usesOriginalWebView &&
            session.isOriginal &&
            !session.scrolling
        ? await ref
              .read(originalLayoutProvider(id))
              .value
              ?.visiblePageAnchor
              ?.call()
        : null;
    final locator = exact ?? anchor;
    traceBookmark('save-request', {
      'locator': bookmarkTraceLocator(locator),
      'sessionAnchor': bookmarkTraceLocator(anchor),
      'fromVisibleDom': exact != null,
      'original': session.isOriginal,
      'scrolling': session.scrolling,
      'fraction': session.chapterProgress,
    });
    final bookmarkId = await repository.addBookmark(
      locator: locator,
      quote: session.currentPageExcerpt,
    );
    traceBookmark('saved', {
      'id': bookmarkId,
      'locator': bookmarkTraceLocator(locator),
    });
  }
}

/// 分页时垂直手势与横向翻页在同一个手势竞技场竞争；滚动不注册下拉手势。
class ReaderBookmarkLayer extends ConsumerStatefulWidget {
  const ReaderBookmarkLayer({
    super.key,
    required this.bookId,
    required this.child,
    required this.allowPull,
    required this.topInset,
    required this.paper,
    this.backgroundImage,
    this.edgeToEdge = false,
  });
  final String bookId;
  final Widget child;
  final bool allowPull;
  final double topInset;
  final Color paper;

  /// 阅读背景图片；下拉时右上角的补块要和纸面用同一张图，不能画成纯色。
  final ui.Image? backgroundImage;
  final bool edgeToEdge;
  @override
  ConsumerState<ReaderBookmarkLayer> createState() => _BookmarkLayerState();
}

class _BookmarkLayerState extends ConsumerState<ReaderBookmarkLayer>
    with SingleTickerProviderStateMixin {
  late final _pdfView = ref.read(pdfViewportProvider(widget.bookId));
  // 条带在 SafeArea 外，横屏时必须补上画布右侧的导航栏/挖孔留白。
  // 系统栏隐藏后使用新 inset，不能保留原来的侧边距离。
  double get _ribbonRight =>
      bookmarkRibbonRight +
      (widget.edgeToEdge ? 0 : MediaQuery.paddingOf(context).right) +
      ((ref
                  .watch(readerSettingsProvider(widget.bookId))
                  .value
                  ?.settings
                  .bookEdges ??
              false)
          ? bookEdgeWidth
          : 0);
  bool get _canPull =>
      !ref.read(pdfModeProvider(widget.bookId)) || _pdfView.canTurn;

  @override
  void initState() {
    super.initState();
    _pdfView.addListener(_viewChanged);
  }

  void _viewChanged() {
    if (!_canPull && _dragging) _finish(cancelled: true);
    if (mounted) setState(() {});
  }

  late final _return = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
  )..addListener(() => setState(() {}));
  double _distance = 0, _releaseOffset = 0;
  bool _saving = false,
      _dragging = false,
      _removing = false,
      _committed = false,
      _awaitingRibbon = false;
  Object? _pendingPage;
  double get _offset => _dragging
      ? math.min(64, _distance * .55)
      : _releaseOffset * (1 - Curves.easeOutCubic.transform(_return.value));

  void _start() {
    if (_saving || _awaitingRibbon || !_canPull) return;
    _return.stop();
    setState(() {
      _distance = 0;
      _dragging = true;
      _committed = false;
      _removing = ref.read(currentBookmarkProvider(widget.bookId)) != null;
    });
  }

  Future<void> _finish({bool cancelled = false}) async {
    if (!_dragging) return;
    final pulled = !cancelled && _canPull && _distance >= 64;
    _releaseOffset = _offset;
    setState(() {
      _dragging = false;
      _committed = pulled;
      _awaitingRibbon = pulled;
      final anchor = ref
          .read(readerSessionProvider(widget.bookId))
          .value
          ?.currentAnchor;
      _pendingPage = (anchor?.chapterId, anchor?.blockId, anchor?.utf16Offset);
    });
    // 保留正文尺寸，只平移整张纸；回位与持久化同时开始。
    if (MediaQuery.disableAnimationsOf(context)) {
      _return.value = 1;
    } else {
      _return.forward(from: 0);
    }
    if (!pulled || _saving) return;
    _saving = true;
    try {
      await toggleReaderBookmark(ref, widget.bookId);
    } catch (appError, appStack) {
      AppErrors.report(appError, appStack, operation: '书签未保存');
      if (mounted) {
        _awaitingRibbon = false;
        ref.read(readerProvider.notifier).showNotice('书签未保存，请重试');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  void dispose() {
    _pdfView.removeListener(_viewChanged);
    _return.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(pdfViewportProvider(widget.bookId));
    final marked = ref.watch(currentBookmarkProvider(widget.bookId)) != null;
    final session = ref.watch(readerSessionProvider(widget.bookId)).value;
    final scrolling = session?.scrolling == true;
    final anchor = session?.currentAnchor;
    final samePage =
        _pendingPage ==
        (anchor?.chapterId, anchor?.blockId, anchor?.utf16Offset);
    final pending = _awaitingRibbon && samePage;
    final original = ref.watch(originalPageBookmarksProvider(widget.bookId));
    // 只有网页原书需要等待DOM回报；PDF书签直接画在原页画布上。
    // 否则PDF会一直等待不存在的DOM信号，过渡条带也无法结束。
    final painted =
        session?.book.format.usesOriginalWebView == true &&
            session?.isOriginal == true &&
            !scrolling
        ? original?.chapter == anchor?.chapterId &&
              original?.ids.isNotEmpty == true
        : marked;
    if (_awaitingRibbon && (!samePage || (!_saving && painted == !_removing))) {
      // 正文接到新书签并完成这一帧后才撤过渡条带，不在数据库回调时提前撤掉。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _awaitingRibbon = false);
      });
    }
    final paper = widget.paper;
    final offset = _offset;
    final pulling = offset > 0;
    return RawGestureDetector(
      behavior: HitTestBehavior.translucent,
      gestures: {
        if (widget.allowPull && _canPull)
          ReaderPullDownRecognizer:
              GestureRecognizerFactoryWithHandlers<ReaderPullDownRecognizer>(
                () => ReaderPullDownRecognizer(debugOwner: this),
                (recognizer) => recognizer
                  ..gestureSettings = MediaQuery.gestureSettingsOf(context)
                  ..onStart = ((_) => _start())
                  ..onUpdate = (event) {
                    if (_dragging) {
                      setState(
                        () =>
                            _distance = math.max(0, _distance + event.delta.dy),
                      );
                    }
                  }
                  ..onEnd = ((_) => _finish())
                  ..onCancel = () => _finish(cancelled: true),
              ),
      },
      child: ClipRect(
        child: Stack(
          children: [
            if (pulling)
              Positioned.fill(
                top: widget.topInset,
                child: const ColoredBox(color: GtPalette.inverseBackground),
              ),
            if (pulling)
              Positioned(
                top: widget.topInset + 14,
                right: _ribbonRight + bookmarkRibbonSize.width + 12,
                child: Opacity(
                  opacity: _dragging
                      ? 1
                      : (offset / _releaseOffset).clamp(0, 1),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        _distance >= 64
                            ? Icons.arrow_upward
                            : Icons.arrow_downward,
                        size: 16,
                        color: GtPalette.inverseText,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '${_distance >= 64 ? '松手' : '下拉'}${_removing ? '删除' : '增加'}书签',
                        style: const TextStyle(
                          color: GtPalette.inverseText,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            Transform.translate(
              // 提示区按需插入时仍保留正文实例，不能重新加载WebView或恢复系统栏。
              key: const ValueKey('bookmark-page'),
              offset: Offset(0, offset),
              child: ClipRect(
                clipper: _PaperClip(widget.topInset),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final pageSize = constraints.biggest;
                    // 下拉时这块补在页角，盖住纸面自带的那条书签；尺寸要比
                    // 固定条带略大一圈，背景图和纸面同一段，不能是纯色。
                    const patchWidth = 22.0, patchHeight = 31.0;
                    final patch = Rect.fromLTWH(
                      pageSize.width - (_ribbonRight - 3) - patchWidth,
                      widget.topInset,
                      patchWidth,
                      patchHeight,
                    );
                    return Stack(
                      children: [
                        widget.child,
                        // 拖动时条带留在背后的提示区，不能跟着纸面再出现一条。
                        if (pulling || pending)
                          Positioned(
                            top: widget.topInset,
                            right: _ribbonRight - 3,
                            width: patchWidth,
                            height: patchHeight,
                            child: CustomPaint(
                              painter: BookmarkCornerPatchPainter(
                                paper: paper,
                                backgroundImage: widget.backgroundImage,
                                pageSize: pageSize,
                                patch: patch,
                              ),
                            ),
                          ),
                        if (scrolling && marked && !pulling)
                          Positioned(
                            top: widget.topInset,
                            right: _ribbonRight,
                            child: IgnorePointer(
                              child: CustomPaint(
                                size: Size(
                                  bookmarkRibbonSize.width,
                                  bookmarkRibbonSize.height,
                                ),
                                painter: const BookmarkRibbonPainter(),
                              ),
                            ),
                          ),
                      ],
                    );
                  },
                ),
              ),
            ),
            if (pulling || (pending && !_removing))
              Positioned(
                // 上沿固定在阅读画布边界；显示状态栏时从安全区下沿开始，全屏时自然是屏幕边缘。
                top: widget.topInset,
                right: _ribbonRight,
                child: IgnorePointer(
                  child: Opacity(
                    opacity:
                        !_dragging &&
                            pulling &&
                            (_committed ? _removing : !_removing)
                        ? (offset / _releaseOffset).clamp(0, 1)
                        : 1,
                    child: CustomPaint(
                      size: Size(
                        bookmarkRibbonSize.width,
                        bookmarkRibbonSize.height + offset * .1875,
                      ),
                      painter: BookmarkRibbonPainter(
                        outline: _removing && (_dragging || _committed),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 下拉书签时盖住纸面旧条带的补块。
///
/// 它和纸面是同一层坐标：只取背景图对应的那一小块画上去，
/// 这样换成阅读背景图片后不会在右上角露出一个纯色方块。
class BookmarkCornerPatchPainter extends CustomPainter {
  const BookmarkCornerPatchPainter({
    required this.paper,
    required this.backgroundImage,
    required this.pageSize,
    required this.patch,
  });
  final Color paper;
  final ui.Image? backgroundImage;
  final Size pageSize;
  final Rect patch;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = paper);
    final image = backgroundImage;
    if (image == null || pageSize.width <= 0 || pageSize.height <= 0) return;
    // 背景图按整页拉伸；这里按补块在页面里的位置取同一段源图。
    final sx = image.width / pageSize.width;
    final sy = image.height / pageSize.height;
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(
        patch.left * sx,
        patch.top * sy,
        patch.width * sx,
        patch.height * sy,
      ),
      Offset.zero & size,
      Paint()..filterQuality = FilterQuality.low,
    );
  }

  @override
  bool shouldRepaint(BookmarkCornerPatchPainter old) =>
      old.paper != paper ||
      old.backgroundImage != backgroundImage ||
      old.pageSize != pageSize ||
      old.patch != patch;
}

// 下拉和回弹均保持纸面直角，只裁掉顶部安全区。
class _PaperClip extends CustomClipper<Rect> {
  const _PaperClip(this.top);
  final double top;
  @override
  Rect getClip(Size size) =>
      Rect.fromLTWH(0, top, size.width, math.max(0, size.height - top));
  @override
  bool shouldReclip(_PaperClip old) => old.top != top;
}
