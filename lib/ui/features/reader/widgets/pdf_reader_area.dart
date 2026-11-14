import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../engine/normalization/text_anchor.dart';
import '../../../../app/di/reading_controls_providers.dart';
import '../../../../core/diagnostics/reader_work_trace.dart';
import '../../../../data/services/pdf_book_controller.dart';
import '../../../../domain/models/reading_settings.dart';
import '../../../core/theme/gt_tokens.dart';
import '../../../core/widgets/book_loading.dart';
import '../view_models/automatic_reading.dart';
import '../view_models/pdf_book_provider.dart';
import '../view_models/pdf_viewport.dart';
import '../view_models/reader_progress_return.dart';
import '../view_models/reader_session_view_model.dart';
import '../view_models/reader_settings_view_model.dart';
import '../view_models/reader_view_model.dart';
import 'automatic_scan_area.dart';
import 'fold_frames.dart';
import 'page_information.dart';
import 'page_turn_area.dart';
import 'reader_information.dart';
import 'scan_frames.dart';
import 'pdf_zoom_surface.dart';

part 'pdf_scroll_area.dart';

/// 原页像素直接交给Flutter，避免每次跳页先压缩PNG再解码。
Future<ui.Image> _pdfBitmap(
  PdfBookController book,
  int index,
  int width,
) async {
  final (w, h, pixels) = await book.raster(index, width);
  return traceReaderWork('pdf.bitmap', () async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(pixels);
    final descriptor = ui.ImageDescriptor.raw(
      buffer,
      width: w,
      height: h,
      pixelFormat: ui.PixelFormat.bgra8888,
    );
    try {
      final codec = await descriptor.instantiateCodec();
      try {
        return (await codec.getNextFrame()).image;
      } finally {
        codec.dispose();
      }
    } finally {
      descriptor.dispose();
      buffer.dispose();
    }
  }, {'page': index});
}

/// PDF使用Flutter画面接入既有五种翻页；没有WebView选文、链接或听书手势。
class PdfReaderArea extends ConsumerStatefulWidget {
  const PdfReaderArea({
    super.key,
    required this.bookId,
    required this.session,
    required this.settings,
  });
  final String bookId;
  final ReaderSession session;
  final ReaderSettingsState settings;
  @override
  ConsumerState<PdfReaderArea> createState() => PdfReaderAreaState();
}

class PdfReaderAreaState extends ConsumerState<PdfReaderArea> {
  final _paged = GlobalKey<_PdfPagedState>();
  final _scroll = GlobalKey<_PdfScrollState>();
  bool get isReady =>
      ref.read(pdfBookProvider(widget.bookId)).hasError ||
      _paged.currentState?._error != null ||
      _scroll.currentState?._error != null ||
      (_paged.currentState?.ready ?? _scroll.currentState?.ready ?? false);
  Future<void> volumeTurn(bool forward) async {
    if (_paged.currentState case final page?) {
      await page.volumeTurn(forward);
    } else {
      await _scroll.currentState?.volumeTurn(forward);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pdf = ref.watch(pdfBookProvider(widget.bookId));
    final view = ref.watch(pdfViewportProvider(widget.bookId));
    final controls = ref.watch(readerProvider);
    final fixedView = ref.watch(pdfFixedViewModeProvider);
    ref.listen(pdfFixedViewModeProvider, (_, enabled) {
      if (enabled || !view.editing) return;
      if (_scroll.currentState case final scroll?) {
        unawaited(scroll.confirmView(false, clampHorizontal: true));
      } else {
        view.confirm();
      }
    });
    final showOverlay =
        !controls.controlsVisible && controls.panel == ReaderPanel.none;
    return ListenableBuilder(
      listenable: view,
      builder: (_, _) => Stack(
        fit: StackFit.expand,
        children: [
          pdf.when(
            data: (book) => widget.session.scrolling
                ? _PdfScroll(
                    key: _scroll,
                    parent: widget,
                    book: book,
                    fixedView: fixedView,
                  )
                : _PdfPaged(
                    key: _paged,
                    parent: widget,
                    book: book,
                    fixedView: fixedView,
                  ),
            loading: () => const Center(child: BookLoading()),
            error: (e, s) => Center(child: Text('PDF无法读取：$e')),
          ),
          if (view.menuVisible && showOverlay)
            PdfZoomMenu(
              view: view,
              colors: widget.settings.theme.controlsColors,
              onConfirm: (reset) {
                if (_scroll.currentState case final scroll?) {
                  unawaited(scroll.confirmView(reset));
                } else {
                  view.confirm(reset: reset);
                }
              },
            ),
        ],
      ),
    );
  }
}

class _PdfPaged extends ConsumerStatefulWidget {
  const _PdfPaged({
    super.key,
    required this.parent,
    required this.book,
    required this.fixedView,
  });
  final PdfReaderArea parent;
  final PdfBookController book;
  final bool fixedView;
  @override
  ConsumerState<_PdfPaged> createState() => _PdfPagedState();
}

class _PdfPagedState extends ConsumerState<_PdfPaged> {
  final _turn = GlobalKey();
  final _scan = GlobalKey<AutomaticScanAreaState>();
  final _images = <int, ui.Image>{};
  final _pending = <int, Future<ui.Image>>{};
  final _information = <int, PageInformation>{};
  Size _size = Size.zero;
  double _edgeTravel = 0;
  bool _edgeDragging = false;
  int _index = -1, _version = 0, _width = 0;
  Object? _requested;
  bool _loading = true;
  Object? _error;
  bool get ready => !_loading && _error == null && _images.containsKey(_index);
  PdfReaderArea get parent => widget.parent;
  ReaderSessionNotifier get session =>
      ref.read(readerSessionProvider(parent.bookId).notifier);
  PdfViewport get view => ref.read(pdfViewportProvider(parent.bookId));
  PageTurnEffect get _effect => widget.fixedView
      ? parent.settings.settings.pageTurnEffect
      : parent.settings.settings.pageTurnEffect.forPdfFreeView();

  Future<void> volumeTurn(bool forward) async {
    if (ready && view.canTurn && (widget.fixedView || _atEdge(forward))) {
      await PageTurnArea.turn(_turn, forward);
    }
  }

  Rect _bounds(int index) {
    final info = _info(index);
    return Rect.fromLTWH(
      0,
      info.top,
      _size.width,
      math.max(1, _size.height - info.top - info.bottom),
    );
  }

  Rect _pageRect(int index) {
    final page = widget.book.file.document.pages[index];
    final bounds = _bounds(index);
    return Alignment.center.inscribe(
      applyBoxFit(
        BoxFit.contain,
        Size(page.width, page.height),
        bounds.size,
      ).destination,
      bounds,
    );
  }

  Offset _limits(int index, double scale) {
    final bounds = _bounds(index);
    final page = _pageRect(index);
    return Offset(
      math.max(0, (page.width * scale - bounds.width) / 2),
      math.max(0, (page.height * scale - bounds.height) / 2),
    );
  }

  Offset _clampOffset(Offset offset, Offset limit) => Offset(
    offset.dx.clamp(-limit.dx, limit.dx),
    offset.dy.clamp(-limit.dy, limit.dy),
  );

  Offset get _currentOffset => widget.fixedView
      ? view.offset
      : _clampOffset(view.offset, _limits(_index, view.scale));

  Offset _landingOffset(int index) {
    if (widget.fixedView) return view.offset;
    final limit = _limits(index, view.scale);
    return _clampOffset(
      Offset(index > _index ? limit.dx : -limit.dx, _currentOffset.dy),
      limit,
    );
  }

  bool _atEdge(bool forward) {
    final limit = _limits(_index, view.scale).dx;
    return (forward ? _currentOffset.dx + limit : limit - _currentOffset.dx) <=
        .5;
  }

  void _zoom(double scale, Offset from, Offset to, bool singleFinger) {
    if (!ready) return;
    final center = _bounds(_index).center;
    final offset =
        to - center - (from - center - _currentOffset) * (scale / view.scale);
    if (widget.fixedView) {
      final limit = _size.center(Offset.zero) * scale;
      final translation = singleFinger ? view.fixedDrag(to - from) : offset;
      view.update(scale, _clampOffset(translation, limit));
    } else {
      view.update(scale, _clampOffset(offset, _limits(_index, scale)));
    }
  }

  void _pan(Offset delta, Offset position) {
    if (!ready) return;
    if (_edgeDragging) {
      final next = _edgeTravel + delta.dx;
      final consumed = next.sign == _edgeTravel.sign ? delta.dx : -_edgeTravel;
      _edgeTravel += consumed;
      PageTurnArea.updateExternalDrag(_turn, position, consumed);
      if (_edgeTravel != 0) return;
      // 拖回到交接点时，剩余的位移重新用来在当前页内平移。
      PageTurnArea.cancelGesture(_turn);
      _edgeDragging = false;
      delta = Offset(delta.dx - consumed, delta.dy);
    }
    final before = _currentOffset;
    final wanted = before + delta;
    final after = _clampOffset(wanted, _limits(_index, view.scale));
    final overflow = wanted.dx - after.dx;
    if (after != before) {
      // 同一个触点可能同时拖完页内并越过边缘。先同步当前画面，
      // 再让翻页控件使用越过边缘后的这段位移。
      view.update(view.scale, after);
    }
    final target = _index + (overflow < 0 ? 1 : -1);
    if (overflow.abs() <= delta.dy.abs() ||
        target < 0 ||
        target >= widget.book.chapters.length) {
      return;
    }
    _edgeDragging = PageTurnArea.beginExternalDrag(
      _turn,
      position - Offset(overflow, 0),
    );
    if (_edgeDragging) {
      _edgeTravel = overflow;
      PageTurnArea.updateExternalDrag(
        _turn,
        position,
        overflow,
        neighbour: _images.containsKey(target) ? _frame(target) : null,
      );
    }
  }

  void _finishPan(bool cancelled, bool startingZoom) {
    _edgeTravel = 0;
    if (_edgeDragging) {
      _edgeDragging = false;
      // 第二指按下由 onBegin 立即取消，普通触摸取消走平移回弹。
      if (!startingZoom) {
        unawaited(PageTurnArea.endExternalDrag(_turn, cancelled: cancelled));
      }
    }
  }

  Future<ui.Image> _image(int index) {
    if (_images[index] case final image?) return Future.value(image);
    return _pending.putIfAbsent(
      index,
      () =>
          () async {
            final image = await _pdfBitmap(widget.book, index, _width);
            if (!mounted) {
              image.dispose();
              throw StateError('PDF显示已结束');
            }
            _images[index] = image;
            return image;
          }().whenComplete(() {
            _pending.remove(index);
          }),
    );
  }

  void _request() {
    final s = parent.session;
    final revision = (
      s.chapterIndex,
      s.originalJump?.token,
      session.displayTarget,
      _width,
    );
    if (_requested == revision) return;
    _requested = revision;
    final version = ++_version;
    _loading = true;
    scheduleMicrotask(() async {
      try {
        final index = s.chapterIndex;
        await _image(index);
        if (!mounted || version != _version) return;
        final content = await widget.book.content(index);
        if (!mounted || version != _version) return;
        final exact = session.takeOriginalExactPosition();
        final target =
            session.displayTarget ??
            exact ??
            (s.originalJump != null
                ? locatorForFraction(
                    content: content,
                    bookId: parent.bookId,
                    contentVersion: s.book.contentVersion,
                    chapterId: content.chapterId,
                    fraction: s.originalJump!.fraction,
                  )
                : s.currentAnchor ?? session.scrollOpeningAnchor);
        setState(() {
          _index = index;
          _loading = false;
          _error = null;
        });
        await WidgetsBinding.instance.endOfFrame;
        if (!mounted || version != _version) return;
        await session.commitPdfPosition(
          index,
          exact: target?.chapterId == content.chapterId ? target : null,
        );
        _neighbors();
      } catch (e, stack) {
        if (!mounted || version != _version) return;
        setState(() {
          _error = e;
          _loading = false;
        });
        session.reportPositionFailure(e, stack);
      }
    });
  }

  void _neighbors() {
    for (final i in [_index - 1, _index + 1]) {
      if (i >= 0 && i < widget.book.chapters.length) {
        unawaited(
          _image(i).then((_) {
            if (mounted) setState(() {});
          }, onError: (Object _) {}),
        );
      }
    }
    // 保留当前及两侧，图像从树和本次折页解绑之后再释放。
    final old = _images.keys.where((i) => (i - _index).abs() > 2).toList();
    for (final i in old) {
      final image = _images.remove(i)!;
      WidgetsBinding.instance.addPostFrameCallback((_) => image.dispose());
    }
  }

  PageInformation _prepareInfo(int index) => readerInformation(
    context,
    ref,
    parent.session,
    parent.settings.settings,
    parent.settings.theme,
    index,
    0,
    showReturnProgress: index == _index && !view.menuVisible,
    bookmarked:
        ref
            .watch(bookmarksProvider(parent.bookId))
            .value
            ?.any(
              (b) => b.locator.chapterId == widget.book.chapters[index].id,
            ) ??
        false,
  );

  PageInformation _info(int index) {
    final held = _information[index];
    if (held != null) return held;
    final base = _information[_index]!;
    return PageInformation(
      chapter: widget.book.chapters[index].title,
      book: base.book,
      progress:
          '${(parent.session.readingProgressAt(index, 0) * 100).toStringAsFixed(2)}%',
      clock: base.clock,
      battery: base.battery,
      inset: base.inset,
      bottomInset: base.bottomInset,
      color: base.color,
      scaler: base.scaler,
      visible: base.visible,
      fontFamily: base.fontFamily,
    );
  }

  _PdfPagePainter _painter(int index) => _PdfPagePainter(
    _images[index]!,
    _info(index),
    parent.settings.theme.background,
    _bounds(index),
    _pageRect(index),
    view.scale,
    index == _index ? _currentOffset : _landingOffset(index),
  );

  Widget _frame(int index) => CustomPaint(painter: _painter(index));

  ui.Image _raster(int index) {
    final ratio = MediaQuery.devicePixelRatioOf(context).clamp(1.0, 2.0);
    final recorder = ui.PictureRecorder();
    _painter(index).paint(Canvas(recorder)..scale(ratio), _size);
    final picture = recorder.endRecording();
    try {
      return picture.toImageSync(
        (_size.width * ratio).ceil(),
        (_size.height * ratio).ceil(),
      );
    } finally {
      picture.dispose();
    }
  }

  Future<bool> _commit(int index) async {
    if (!ready || !view.canTurn) return false;
    if (index < 0 || index >= widget.book.chapters.length) {
      ref
          .read(readerProvider.notifier)
          .showNotice(index < 0 ? '已到全书开头' : '已到全书末尾');
      return false;
    }
    final version = _version;
    await _image(index);
    if (!mounted || version != _version || !view.canTurn) return false;
    final landing = _landingOffset(index);
    final commitVersion = ++_version;
    ref
        .read(readerProgressReturnProvider(parent.bookId).notifier)
        .pageChanged();
    setState(() {
      _index = index;
      _loading = false;
    });
    view.confirm(landing: landing);
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || commitVersion != _version) return false;
    await session.commitPdfPosition(index);
    if (!mounted || commitVersion != _version) return true;
    // 自己提交引起的会话更新不是另一次外部跳转。
    final s = ref.read(readerSessionProvider(parent.bookId)).requireValue;
    _requested = (
      s.chapterIndex,
      s.originalJump?.token,
      session.displayTarget,
      _width,
    );
    _neighbors();
    return true;
  }

  @override
  void dispose() {
    ++_version;
    for (final image in _images.values) {
      image.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      _size = constraints.biggest;
      _width = (_size.width * MediaQuery.devicePixelRatioOf(context))
          .round()
          .clamp(360, 1600);
      _request();
      if (_error != null) return Center(child: Text('PDF页面无法显示：$_error'));
      if (_index < 0 || !_images.containsKey(_index)) {
        return const Center(child: BookLoading());
      }
      final last = widget.book.chapters.length - 1;
      for (final index in _images.keys) {
        _information[index] = _prepareInfo(index);
      }
      return PdfZoomSurface(
        view: view,
        fixedView: widget.fixedView,
        canStart: () => ready && !PageTurnArea.settling(_turn),
        onZoom: _zoom,
        onPan: _pan,
        onPanStart: () => unawaited(session.beginManualReading()),
        onPanEnd: _finishPan,
        onBegin: () {
          PageTurnArea.cancelGesture(_turn);
          unawaited(session.beginManualReading());
        },
        child: AutomaticScanArea(
          key: _scan,
          bookId: parent.bookId,
          page: (
            bookId: parent.bookId,
            contentVersion: parent.session.book.contentVersion,
            layout: (_size, _width, view.revision),
            page: _index,
          ),
          ready: () => ready && view.canTurn,
          bounds: Offset.zero & _size,
          paper: parent.settings.theme.background,
          line: parent.settings.theme.primary,
          prepare: (cover) async {
            final current = _raster(_index);
            cover(current);
            if (_index == last) {
              return ScanPreparation(ScanFrames(current, null), null);
            }
            final next = _index + 1;
            try {
              await _image(next);
              return ScanPreparation(
                ScanFrames(current, _raster(next)),
                () async {
                  await _commit(next);
                },
                targetPage: next,
              );
            } catch (_) {
              current.dispose();
              rethrow;
            }
          },
          child: PageTurnArea(
            key: _turn,
            currentPage: _frame(_index),
            previousPage: _images.containsKey(_index - 1)
                ? _frame(_index - 1)
                : null,
            nextPage: _images.containsKey(_index + 1)
                ? _frame(_index + 1)
                : null,
            turnId: _index,
            effect: _effect,
            inputRevision: (_requested, view.revision, widget.fixedView),
            inputAllowed: () => ready && view.canTurn,
            dragEnabled: widget.fixedView || view.scale <= 1,
            requireDragDistance: !widget.fixedView,
            onTapIntercept: widget.fixedView
                ? null
                : (position) async =>
                      position.dx < _size.width * GtReadingTapZones.previousEdge
                      ? !_atEdge(false)
                      : position.dx >
                                _size.width * GtReadingTapZones.nextEdge &&
                            !_atEdge(true),
            traceLabel: 'pdf',
            onCenterTap: () => ref
                .read(automaticReadingProvider(parent.bookId).notifier)
                .centerTap(),
            onManualStart: () => unawaited(session.beginManualReading()),
            onTurn: (direction) => _commit(
              _index + (direction == PageTurnDirection.forward ? 1 : -1),
            ),
            resolvePage: (direction) async {
              final target =
                  _index + (direction == PageTurnDirection.forward ? 1 : -1);
              if (target < 0 || target > last) return null;
              final alreadyReady = _images.containsKey(target);
              await _image(target);
              if (!alreadyReady && mounted) setState(() {});
              return mounted ? _frame(target) : null;
            },
            // 平移直接绘制已解码位图。拖到边缘的同一帧就能更新两页的位置。
            prepareFold: switch (_effect) {
              PageTurnEffect.curl || PageTurnEffect.cover => (direction) async {
                final backward = direction == PageTurnDirection.backward;
                final target = _index + (backward ? -1 : 1);
                if (target < 0 || target > last) return null;
                await _image(target);
                return FoldFrames.images(
                  _raster(_index),
                  _raster(target),
                  _size,
                  backward: backward,
                  paper: parent.settings.theme.background,
                );
              },
              _ => null,
            },
          ),
        ),
      );
    },
  );
}

class _PdfPagePainter extends CustomPainter {
  _PdfPagePainter(
    this.image,
    this.info,
    this.paper,
    this.bounds,
    this.rect,
    this.scale,
    this.offset,
  );
  final ui.Image image;
  final PageInformation info;
  final Color paper;
  final Rect bounds, rect;
  final double scale;
  final Offset offset;
  @override
  void paint(Canvas canvas, Size size) {
    // 平移时两张页共用画布；底色也必须限制在本页，不能盖住正在进入的邻页。
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    canvas.drawColor(paper, BlendMode.src);
    canvas.save();
    canvas.clipRect(bounds);
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Rect.fromCenter(
        center: bounds.center + offset,
        width: rect.width * scale,
        height: rect.height * scale,
      ),
      Paint()..filterQuality = FilterQuality.medium,
    );
    canvas.restore();
    info.paint(canvas, size);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_PdfPagePainter old) =>
      old.image != image ||
      old.info.paintingKey != info.paintingKey ||
      old.bounds != bounds ||
      old.rect != rect ||
      old.scale != scale ||
      old.offset != offset ||
      old.paper != paper;
}
