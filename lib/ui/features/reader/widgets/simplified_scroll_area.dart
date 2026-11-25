import 'reader_link_ink.dart';

import 'dart:async';

import 'package:taletin/core/diagnostics/app_errors.dart';

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/scheduler.dart';
import 'package:flutter/gestures.dart' show DragStartBehavior;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'table_painter.dart';
import 'reader_text_painter.dart';
import 'block_background_paint.dart';
import '../../../../engine/layout/chapter_paginator.dart';
import '../../../../engine/layout/measured_block.dart' show BlockBox;
import '../../../core/theme/reading_theme.dart';
import 'footnote_popover.dart';

import '../../../../app/di/app_providers.dart';
import '../../../../app/di/reading_controls_providers.dart';
import '../../../../domain/models/locator.dart' show SelectionRange;
import '../../../../domain/models/book.dart';
import '../../../../engine/layout/layout_options.dart';
import '../../../../engine/layout/measured_paragraphs.dart';
import '../../../../engine/layout/scroll_chapter.dart';
import '../../../../engine/selection/scroll_selection.dart';
import '../../../../engine/selection/selection_range.dart';
import '../../../core/theme/gt_tokens.dart';
import '../../../core/widgets/book_loading.dart';
import '../view_models/reader_session_view_model.dart';
import '../view_models/reader_settings_view_model.dart';
import '../view_models/reader_view_model.dart';
import '../view_models/reader_source_change.dart';
import '../view_models/scroll_window.dart';
import '../view_models/original_layout_controller.dart';
import '../view_models/automatic_reading.dart';
import 'page_information.dart';
import 'reader_information.dart';
import 'book_paper.dart';
import 'book_shadow_paint.dart';
import 'scroll_resources.dart';
import 'scroll_cell_sliver.dart';
import 'scroll_text_pictures.dart';
import 'scroll_css_background.dart';
import 'css_background_paint.dart';
import '../../../../engine/layout/book_background.dart';
import '../../../../core/diagnostics/reader_turn_diagnostics.dart';
import '../../../../platform/reading_font_binding.dart';
import 'scroll_selection_layer.dart';
import 'reader_image_viewer.dart';
import 'reader_image_gallery.dart';

part 'simplified_automatic_motion.dart';
part 'simplified_scroll_selection.dart';
part 'simplified_scroll_tap.dart';
part 'scroll_text_paint.dart';

class SimplifiedScrollArea extends ConsumerStatefulWidget {
  const SimplifiedScrollArea({
    super.key,
    required this.bookId,
    required this.session,
    required this.settings,
  });
  final String bookId;
  final ReaderSession session;
  final ReaderSettingsState settings;
  @override
  ConsumerState<SimplifiedScrollArea> createState() =>
      SimplifiedScrollAreaState();
}

class SimplifiedScrollAreaState extends ConsumerState<SimplifiedScrollArea>
    with
        SingleTickerProviderStateMixin,
        _SimplifiedAutomaticMotion,
        _SimplifiedScrollSelection,
        _SimplifiedScrollTap {
  @override
  late final ScrollWindow _window;
  @override
  late final ScrollResources _resources;
  final _textPictures = ScrollTextPictures();
  Iterator<int>? _nearbyText;
  bool _textTaskScheduled = false;
  late final _paragraphs = MeasuredParagraphs(
    (caption) => caption
        ? widget.settings.theme.secondary
        : widget.settings.theme.primary,
  );
  final _headerChapter = ValueNotifier<ScrollChapter?>(null);
  BookShadowCache? _shadows;
  Timer? _reportTimer;
  bool _chapterFailed = false;
  bool _completionDrag = false;
  String? _signature;
  int? _jump;
  int _preparation = 0;
  double? _stableHeight;
  late final ReaderSessionNotifier _cachedSession;
  @override
  ReaderSessionNotifier get _session => _cachedSession;
  bool get isReady =>
      _window.isReady && _window.options?.layoutSignature == _signature;

  Future<void> volumeTurn(bool forward) =>
      scrollBy(forward ? 1 : -1, byPage: true);

  Future<void> scrollBy(double delta, {bool byPage = false}) async {
    if (!isReady || !_window.controller.hasClients || _window.busy) return;
    await _automatic.discard();
    await _session.beginManualReading();
    await _window.maintain();
    await _warmNearby();
    if (!mounted || !isReady || !_window.controller.hasClients) return;
    final position = _window.controller.position;
    _window.controller.jumpTo(
      (position.pixels +
              (byPage ? position.viewportDimension * .85 * delta : delta))
          .clamp(position.minScrollExtent, position.maxScrollExtent),
    );
    _window.report();
  }

  @override
  void initState() {
    super.initState();
    _cachedSession = ref.read(readerSessionProvider(widget.bookId).notifier);
    _resources = ScrollResources(
      (path) => ref
          .read(chapterContentRepositoryProvider)
          .resourceAbsolutePath(
            widget.bookId,
            widget.session.book.contentVersion,
            path,
          ),
      formulaColor: () => widget.settings.theme.primary,
      readingTheme: () => widget.settings.theme,
      pixelRatio: () => View.of(context).devicePixelRatio,
      paperSize: () => MediaQuery.sizeOf(context),
      onBackdropChanged: (chapter) {
        // 尚未放入窗口的章节会在准备好后一起显示。已显示的纸色到达时立即更新文字。
        if (mounted &&
            _window.entries.any((entry) => identical(entry.layout, chapter))) {
          setState(() {});
        }
      },
    );
    _window = ScrollWindow(
      paragraphs: _paragraphs,
      bookId: widget.bookId,
      version: widget.session.book.contentVersion,
      chapters: widget.session.chapters,
      load: (chapter) => ref
          .read(chapterContentRepositoryProvider)
          .chapter(widget.bookId, chapter),
      loadTxtSections: widget.session.book.format == BookFormat.txt
          ? (chapter) => ref
                .read(chapterContentRepositoryProvider)
                .txtChapterSource(widget.bookId, chapter)
          : null,
      prepareFonts: ref.read(publicationFontLoaderProvider).prepare,
      onPosition: (content, anchor, token) {
        if (mounted) {
          final entry = _window.visible()?.entry;
          if (_session.reportScrollPosition(
            content,
            anchor,
            jumpToken: token,
            sectionOffset: entry != null && entry.sectioned
                ? entry.textOffset
                : null,
            atEnd:
                _window.reachesBookEnd &&
                _window.controller.offset >=
                    _window.controller.position.maxScrollExtent - .5,
          )) {
            _session.completeAnnotationLanding();
          }
        }
      },
      prepareResources: _resources.warm,
      preparePaperHeight: _resources.fullWidthPaperHeight,
      onError: _loadingFailed,
    );
    _window.addListener(_changed);
    _window.controller.addListener(_scrolled);
    _initAutomatic();
    _initSelection(_contentTap, _contentLinkAt);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final ratio = MediaQuery.devicePixelRatioOf(context);
    if (_shadows?.pixelRatio != ratio) {
      _shadows?.dispose();
      _textPictures.dispose();
      _shadows = BookShadowCache(ratio);
    }
  }

  void _changed() {
    _nearbyText = null;
    if (isReady) _prepareNearbyText();
    _retainNearby();
    _headerChapter.value = _window.visible()?.entry.layout;
    if (mounted) setState(() {});
  }

  void _retainNearby() {
    if (!_window.controller.hasClients || !_window.isReady) return;
    final paths = <String>{};
    var before = 0.0;
    for (final entry in _window.entries) {
      paths.addAll(
        _resources.pathsNear(
          entry.layout,
          _window.controller.offset - before,
          _window.options!.contentHeight,
        ),
      );
      before += entry.layout.height;
    }
    _resources.retain(paths);
  }

  void _scrolled() {
    // 跳转中的位置通知只用于让正文按新坐标布局。落位后由窗口统一回报和补章。
    if (_window.isLanding) return;
    // 页眉墨色只取决于页首所在章的纸色。章内移动不需要逐帧重建信息栏。
    _headerChapter.value = _window.visible()?.entry.layout;
    _reportTimer ??= Timer(const Duration(milliseconds: 250), () {
      _reportTimer = null;
      if (!mounted) return;
      _window.report();
      _retainNearby();
      unawaited(_warmNearby());
    });
    if (!_chapterFailed) {
      unawaited(_window.maintain().catchError(_loadingFailed));
    }
  }

  Future<void> _warmNearby() async {
    if (!_window.controller.hasClients || !_window.isReady) return;
    var before = 0.0;
    final jobs = <Future<void>>[];
    // 一屏可能包含几章，下一章的图片进入屏幕前也必须准备。
    for (final entry in _window.entries) {
      jobs.add(
        _resources.warm(
          entry.layout,
          _window.controller.offset - before,
          _window.options!.contentHeight,
        ),
      );
      before += entry.layout.height;
    }
    await Future.wait(jobs);
    // 图片自己的画笔监听 ScrollResources；没有新章节时无需重建整个列表。
  }

  void _loadingFailed(Object error, StackTrace stack) {
    if (!mounted) return;
    if (isSourceChange(error)) {
      ref
          .read(readerSourceChangeProvider(widget.bookId).notifier)
          .markChanged();
      return;
    }
    _chapterFailed = true;
    AppErrors.report(error, stack, operation: '滚动章节读取失败');
    _automatic.finish('章节读取失败，已暂停；可再次开始重试');
  }

  @override
  void dispose() {
    final binding = WidgetsBinding.instance;
    if (binding is ReadingFontBinding) {
      binding.setReaderMoving(this, false, closing: true);
    }
    _disposeAutomatic();
    _reportTimer?.cancel();
    _window.removeListener(_changed);
    _window.dispose();
    _paragraphs.dispose();
    _headerChapter.dispose();
    _resources.dispose();
    _textPictures.dispose();
    _shadows?.dispose();
    super.dispose();
  }

  void _prepare(LayoutOptions options) {
    final jump = widget.session.scrollJump;
    if (_signature == options.layoutSignature && _jump == jump?.token) return;
    final requested = _jump != jump?.token;
    _chapterFailed = false;
    _signature = options.layoutSignature;
    _jump = jump?.token;
    final preparation = ++_preparation;
    final anchor = requested
        ? jump?.locator ?? _session.scrollOpeningAnchor
        : _session.scrollOpeningAnchor;
    final index = anchor == null
        ? widget.session.chapterIndex
        : widget.session.chapters.indexWhere((c) => c.id == anchor.chapterId);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || preparation != _preparation) return;
      await _session.setScrolling(true);
      try {
        await _window.open(
          index,
          options,
          anchor,
          jumpToken: jump?.token,
          animated: jump != null && _session.speechScrollToken == jump.token,
        );
      } on Object catch (error, stack) {
        AppErrors.report(error, stack, operation: '滚动正文准备失败', notify: mounted);
        if (mounted) {
          if (isSourceChange(error)) {
            ref
                .read(readerSourceChangeProvider(widget.bookId).notifier)
                .markChanged();
            return;
          }
          ref.read(readerProvider.notifier).showNotice('正文准备失败：$error');
        }
      }
    });
  }

  ScrollCellSliver? _body;
  (List<double>, double, ReadingTheme, BookShadowCache?, int)? _bodyInputs;

  ScrollCellSliver _bodySliver(double paperWidth) {
    // 阅读位置、时钟会触发外层重建。只有正文的尺寸、画法或章节窗口变化才更新段落。
    final inputs = (
      _window.cellOffsets,
      paperWidth,
      widget.settings.theme,
      _shadows,
      _resources.backdropRevision,
    );
    if (_bodyInputs == inputs) return _body!;
    _bodyInputs = inputs;
    WidgetsBinding.instance.addPostFrameCallback((_) => _prepareNearbyText());
    return _body = ScrollCellSliver(
      offsets: _window.cellOffsets,
      delegate: _ScrollCellsDelegate(
        (context, i) {
          final entry = _window.cellAt(i);
          final cell = entry.cell;
          final painter = _textPainter(entry.entry.layout, cell);
          final options = painter.options;
          final theme = widget.settings.theme;
          final text = CustomPaint(painter: painter);
          final images = cell.positionedImages(options.contentWidth).toList();
          final inline = cell.positionedInlineImages.toList();
          if (images.isEmpty && inline.isEmpty) {
            return KeyedSubtree(key: _window.keyAt(i), child: text);
          }
          return ClipRect(
            key: _window.keyAt(i),
            clipper: _PaperWidthClip((paperWidth - options.contentWidth) / 2),
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned.fill(child: text),
                for (final (:block, :rect) in images)
                  Positioned.fromRect(
                    rect: rect,
                    child: CustomPaint(
                      painter: block.box == null
                          ? null
                          : _ImageBoxPainter(
                              block.box!,
                              theme,
                              _resources.backgroundInfo,
                              _shadows!.paint,
                            ),
                      child: _resources.view(
                        block.resourcePath!,
                        rect.size,
                        theme.secondary,
                        block.alt,
                        block.imageFit,
                      ),
                    ),
                  ),
                for (final visual in inline)
                  Positioned.fromRect(
                    rect: visual.rect,
                    child: _resources.view(
                      visual.image.resourcePath,
                      visual.rect.size,
                      cell.table.isEmpty ? theme.secondary : theme.primary,
                      visual.image.alt,
                      visual.image.imageFit,
                    ),
                  ),
              ],
            ),
          );
        },
        count: _window.cellCount,
        height: _window.height,
        findIndex: _window.indexOfKey,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final settings = widget.settings.settings;
      final info = readerInformation(
        context,
        ref,
        widget.session,
        settings,
        widget.settings.theme,
        widget.session.chapterIndex,
        widget.session.chapterProgress,
      );
      if (MediaQuery.viewInsetsOf(context).bottom == 0) {
        _stableHeight = box.maxHeight;
      }
      final height = _stableHeight ?? box.maxHeight;
      final width = math.min(
        box.maxWidth,
        settings.landscape ? box.maxWidth : GtSize.readingMaxWidth,
      );
      final options = LayoutOptions(
        cssDark: widget.settings.theme.isNight,
        settings: settings,
        paperInset: Offset(
          (box.maxWidth - width) / 2 +
              settings.horizontalPadding +
              (settings.bookEdges ? bookEdgeWidth : 0),
          0,
        ),
        contentSize: Size(
          width -
              2 *
                  (settings.horizontalPadding +
                      (settings.bookEdges ? bookEdgeWidth : 0)),
          height - info.top - info.bottom - 48,
        ),
        textScaler: MediaQuery.textScalerOf(context),
        // 只有 TXT 补章题和短横线；EPUB／MOBI／AZW3 按原书内容与样式排。
        insertChapterTitle: widget.session.book.format == BookFormat.txt,
      );
      _prepare(options);
      if (_window.options == null) return const Center(child: BookLoading());
      final hasChapterPaper = _window.entries.any(
        (entry) =>
            chapterBackground(entry.layout.content, _window.options!) != null,
      );
      return Stack(
        children: [
          Positioned.fill(
            child: CustomPaint(
              painter: ReadingBackgroundPainter(
                widget.settings.theme.background,
                widget.settings.theme.texture?.image,
              ),
            ),
          ),
          if (hasChapterPaper)
            Positioned.fill(
              child: IgnorePointer(
                child: RepaintBoundary(
                  child: CustomPaint(
                    painter: ScrollCssBackgroundPainter(
                      _window,
                      _resources,
                      widget.settings.theme,
                      info.top + 24,
                    ),
                  ),
                ),
              ),
            ),
          Positioned.fill(
            // 前面会按章节插入或移除背景层。让正文列表在 Stack 中保持同一实例，
            // 否则交接的一帧会有两个 ScrollPosition 同时挂在同一个控制器上。
            key: const ValueKey('scroll-viewport'),
            top: info.top + 24,
            bottom: info.bottom + 24,
            left: (box.maxWidth - _window.options!.contentWidth) / 2,
            right: (box.maxWidth - _window.options!.contentWidth) / 2,
            child: NotificationListener<ScrollNotification>(
              onNotification: (event) {
                final binding = WidgetsBinding.instance;
                if (event.depth == 0 &&
                    binding is ReadingFontBinding &&
                    (event is ScrollStartNotification ||
                        event is ScrollEndNotification)) {
                  binding.setReaderMoving(
                    this,
                    event is ScrollStartNotification,
                  );
                }
                if (event is ScrollStartNotification) _nearbyText = null;
                if (event is ScrollStartNotification &&
                    event.dragDetails != null) {
                  _completionDrag = true;
                  unawaited(_session.beginManualReading());
                }
                if (event is ScrollEndNotification && !_autoTicker.isActive) {
                  if (_completionDrag &&
                      _window.reachesBookEnd &&
                      event.metrics.extentAfter < 1) {
                    ref.read(readerProvider.notifier).showNotice('已到全书末尾');
                  }
                  WidgetsBinding.instance.addPostFrameCallback(
                    (_) => _prepareNearbyText(),
                  );
                  _completionDrag = false;
                  _window.report();
                  unawaited(_session.persist());
                }
                return false;
              },
              child: ClipRect(
                clipper: _PaperWidthClip(
                  (box.maxWidth - _window.options!.contentWidth) / 2,
                ),
                child: ReaderLinkPress(
                  bookId: widget.bookId,
                  hit: (point) {
                    final model = _selectionModel();
                    return model == null
                        ? null
                        : readerLinkAtScrollPoint(model, point)?.link;
                  },
                  child: ScrollSelectionLayer(
                    key: _scrollViewportKey,
                    bookId: widget.bookId,
                    backend: _selectionBackend,
                    theme: widget.settings.theme,
                    enableDictionary: true,
                    child: CustomScrollView(
                      key: const ValueKey('continuous-text'),
                      // 仍由手势竞争区分点按、长按；确认纵向拖动时立即兑现已移动的距离。
                      dragStartBehavior: DragStartBehavior.down,
                      clipBehavior: Clip.none,
                      controller: _window.controller,
                      scrollCacheExtent: const ScrollCacheExtent.pixels(500),
                      slivers: [_bodySliver(box.maxWidth)],
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (settings.bookEdges)
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  painter: BookPaperPainter(
                    widget.settings.theme.background,
                    backgroundImage: widget.settings.theme.texture?.image,
                    decorationOnly: true,
                    preserveBackground:
                        hasChapterPaper ||
                        _window.entries.any((entry) {
                          final first =
                              entry.layout.cells.firstOrNull?.measured;
                          return first?.imageSize != null && first!.inset < 0;
                        }),
                  ),
                ),
              ),
            ),
          Positioned.fill(
            child: IgnorePointer(
              child: RepaintBoundary(
                child: ListenableBuilder(
                  listenable: hasChapterPaper
                      ? Listenable.merge([_headerChapter, _resources])
                      : kAlwaysDismissedAnimation,
                  builder: (_, _) => CustomPaint(
                    painter: ScrollInformationPainter(
                      scrollInformation(
                        info,
                        _window,
                        _resources,
                        widget.settings.theme,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    },
  );
}

/// 行高已经测好，告诉列表真实总高度，避免临近书末时用平均行高估算并回弹。
class _ScrollCellsDelegate extends SliverChildBuilderDelegate {
  _ScrollCellsDelegate(
    super.builder, {
    required int count,
    required this.height,
    required ChildIndexGetter findIndex,
  }) : super(childCount: count, findChildIndexCallback: findIndex);
  final double height;
  @override
  double estimateMaxScrollOffset(
    int firstIndex,
    int lastIndex,
    double leadingScrollOffset,
    double trailingScrollOffset,
  ) => height;
}

/// 滚动仍按正文宽度断行，绘制可以进入左右纸边；纵向按视口或当前图片切片裁剪。
class _PaperWidthClip extends CustomClipper<Rect> {
  const _PaperWidthClip(this.margin);
  final double margin;
  @override
  Rect getClip(Size size) =>
      Rect.fromLTRB(-margin, 0, size.width + margin, size.height);
  @override
  bool shouldReclip(_PaperWidthClip old) => old.margin != margin;
}

class _ImageBoxPainter extends CustomPainter {
  const _ImageBoxPainter(this.box, this.theme, this.images, this.paintShadows);
  final BlockBox box;
  final ReadingTheme theme;
  final BookImageLookup images;
  final BookShadowPainter paintShadows;
  @override
  void paint(Canvas canvas, Size size) => paintImageBox(
    canvas,
    Offset.zero & size,
    box,
    theme,
    images: images,
    paintShadows: paintShadows,
  );
  @override
  bool shouldRepaint(_ImageBoxPainter old) =>
      old.box != box ||
      old.theme != theme ||
      old.images != images ||
      old.paintShadows != paintShadows;
}

class ScrollInformationPainter extends CustomPainter {
  ScrollInformationPainter(this.info);
  final PageInformation info;
  @override
  void paint(Canvas canvas, Size size) => info.paint(canvas, size);
  @override
  bool shouldRepaint(ScrollInformationPainter old) =>
      info.paintingKey != old.info.paintingKey;
}
