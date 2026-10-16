import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/di/app_providers.dart';
import '../../../../domain/models/bookmark.dart';
import '../view_models/reader_session_view_model.dart';
import '../view_models/reader_view_model.dart';
import '../view_models/original_layout_controller.dart';
import '../../../core/theme/gt_tokens.dart';
import 'bookmark_ribbon.dart';
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
  for (final mark in marks) {
    if (mark.locator.needsRelocation) continue;
    if (session.isOriginal &&
        !session.scrolling &&
        original?.chapter == anchor.chapterId) {
      if (original!.ids.contains(mark.id)) return mark;
      continue; // 原书页首可能跨段，已取得DOM页码后不再用近似页首匹配上一页。
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
    await repository.removeBookmark(mark.id);
  } else {
    final exact = session.isOriginal && !session.scrolling
        ? await ref
              .read(originalLayoutProvider(id))
              .value
              ?.visiblePageAnchor
              ?.call()
        : null;
    await repository.addBookmark(
      locator: exact ?? anchor,
      quote: session.currentPageExcerpt,
    );
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
  });
  final String bookId;
  final Widget child;
  final bool allowPull;
  final double topInset;
  final Color paper;
  @override
  ConsumerState<ReaderBookmarkLayer> createState() => _BookmarkLayerState();
}

class _BookmarkLayerState extends ConsumerState<ReaderBookmarkLayer>
    with SingleTickerProviderStateMixin {
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
    if (_saving || _awaitingRibbon) return;
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
    final pulled = !cancelled && _distance >= 64;
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
    } catch (_) {
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
    _return.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final marked = ref.watch(currentBookmarkProvider(widget.bookId)) != null;
    final session = ref.watch(readerSessionProvider(widget.bookId)).value;
    final scrolling = session?.scrolling == true;
    final anchor = session?.currentAnchor;
    final samePage =
        _pendingPage ==
        (anchor?.chapterId, anchor?.blockId, anchor?.utf16Offset);
    final pending = _awaitingRibbon && samePage;
    final original = ref.watch(originalPageBookmarksProvider(widget.bookId));
    final painted = session?.isOriginal == true && !scrolling
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
        if (widget.allowPull)
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
                right: bookmarkRibbonRight + bookmarkRibbonSize.width + 12,
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
                child: Stack(
                  children: [
                    widget.child,
                    // 拖动时条带留在背后的提示区，不能跟着纸面再出现一条。
                    if (pulling || pending)
                      Positioned(
                        top: widget.topInset,
                        right: bookmarkRibbonRight - 3,
                        width: 22,
                        height: 31,
                        child: ColoredBox(color: paper),
                      ),
                    if (scrolling && marked && !pulling)
                      Positioned(
                        top: widget.topInset,
                        right: bookmarkRibbonRight,
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
                ),
              ),
            ),
            if (pulling || (pending && !_removing))
              Positioned(
                // 上沿固定在阅读画布边界；显示状态栏时从安全区下沿开始，全屏时自然是屏幕边缘。
                top: widget.topInset,
                right: bookmarkRibbonRight,
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
